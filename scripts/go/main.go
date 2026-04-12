// stress_test_go — High-throughput stress test for the workload ASG through the NLB.
//
// Generates HTTP traffic in cycles: stress → rest → repeat.
// Designed to trigger ASG CPU-based auto scaling.
//
// Usage:
//
//	go run main.go
//	go run main.go -workers 5000 -stress 300 -rest 60
//	go run main.go -cycles 3 -output results.json
//
// Build:
//
//	go build -o stress_test . && ./stress_test
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"math"
	"math/rand"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

// -- Config from defaults.json ------------------------------------------------

type Config struct {
	DefaultURL     string `json:"DEFAULT_URL"`
	DefaultWorkers int    `json:"DEFAULT_WORKERS"`
	DefaultStress  int    `json:"DEFAULT_STRESS_SECS"`
	DefaultRest    int    `json:"DEFAULT_REST_SECS"`
	DefaultTimeout int    `json:"DEFAULT_TIMEOUT"`
	ReportInterval int    `json:"REPORT_INTERVAL"`
	DefaultASGName string `json:"DEFAULT_ASG_NAME"`
	DefaultRegion  string `json:"DEFAULT_REGION"`
}

func loadConfig() Config {
	cfg := Config{
		DefaultWorkers: 1000,
		DefaultStress:  300,
		DefaultRest:    60,
		DefaultTimeout: 10,
		ReportInterval: 5,
		DefaultASGName: "workload-asg",
		DefaultRegion:  "us-east-2",
	}

	exe, err := os.Executable()
	if err == nil {
		data, err := os.ReadFile(filepath.Join(filepath.Dir(exe), "..", "defaults.json"))
		if err == nil {
			json.Unmarshal(data, &cfg)
			return cfg
		}
	}

	// Fallback: look relative to working directory
	for _, path := range []string{"scripts/defaults.json", "defaults.json", "../defaults.json"} {
		data, err := os.ReadFile(path)
		if err == nil {
			json.Unmarshal(data, &cfg)
			break
		}
	}

	if cfg.DefaultASGName == "" {
		cfg.DefaultASGName = "workload-asg"
	}
	if cfg.DefaultRegion == "" {
		cfg.DefaultRegion = "us-east-2"
	}

	return cfg
}

// -- Streaming stats with reservoir sampling ----------------------------------

type Stats struct {
	mu            sync.Mutex
	count         int64
	total         float64
	sumSq         float64
	min           float64
	max           float64
	statuses      map[int]int64
	reservoir     []float64
	reservoirSize int
	rng           *rand.Rand
}

func NewStats(reservoirSize int) *Stats {
	return &Stats{
		min:           math.Inf(1),
		max:           math.Inf(-1),
		statuses:      make(map[int]int64),
		reservoir:     make([]float64, 0, reservoirSize),
		reservoirSize: reservoirSize,
		rng:           rand.New(rand.NewSource(time.Now().UnixNano())),
	}
}

func (s *Stats) Record(status int, latencyMs float64) {
	s.mu.Lock()
	s.count++
	s.total += latencyMs
	s.sumSq += latencyMs * latencyMs
	if latencyMs < s.min {
		s.min = latencyMs
	}
	if latencyMs > s.max {
		s.max = latencyMs
	}
	s.statuses[status]++

	// Reservoir sampling (Algorithm R)
	if len(s.reservoir) < s.reservoirSize {
		s.reservoir = append(s.reservoir, latencyMs)
	} else {
		j := s.rng.Int63n(s.count)
		if j < int64(s.reservoirSize) {
			s.reservoir[j] = latencyMs
		}
	}
	s.mu.Unlock()
}

type Snapshot struct {
	Count    int64          `json:"count"`
	OK       int64          `json:"ok"`
	Errors   int64          `json:"errors"`
	AvgMs    float64        `json:"avg_ms"`
	MinMs    float64        `json:"min_ms"`
	MaxMs    float64        `json:"max_ms"`
	P50Ms    float64        `json:"p50_ms"`
	P95Ms    float64        `json:"p95_ms"`
	P99Ms    float64        `json:"p99_ms"`
	StddevMs float64        `json:"stddev_ms"`
	Statuses map[int]int64  `json:"statuses"`
}

func (s *Stats) Snapshot() Snapshot {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.count == 0 {
		return Snapshot{Statuses: make(map[int]int64)}
	}

	avg := s.total / float64(s.count)
	variance := (s.sumSq / float64(s.count)) - (avg * avg)
	if variance < 0 {
		variance = 0
	}

	ok := s.statuses[200]

	// Copy and sort reservoir for percentiles
	r := make([]float64, len(s.reservoir))
	copy(r, s.reservoir)
	sort.Float64s(r)
	n := len(r)

	var p50, p95, p99 float64
	if n > 0 {
		p50 = r[n/2]
		p95 = r[int(float64(n)*0.95)]
		p99 = r[int(float64(n)*0.99)]
	}

	statuses := make(map[int]int64, len(s.statuses))
	for k, v := range s.statuses {
		statuses[k] = v
	}

	return Snapshot{
		Count:    s.count,
		OK:       ok,
		Errors:   s.count - ok,
		AvgMs:    math.Round(avg*10) / 10,
		MinMs:    math.Round(s.min*10) / 10,
		MaxMs:    math.Round(s.max*10) / 10,
		P50Ms:    math.Round(p50*10) / 10,
		P95Ms:    math.Round(p95*10) / 10,
		P99Ms:    math.Round(p99*10) / 10,
		StddevMs: math.Round(math.Sqrt(variance)*10) / 10,
		Statuses: statuses,
	}
}

// -- HTTP client with connection pooling --------------------------------------

func newHTTPClient(timeout time.Duration) *http.Client {
	transport := &http.Transport{
		MaxIdleConns:        500,
		MaxIdleConnsPerHost: 500,
		MaxConnsPerHost:     0,
		IdleConnTimeout:     90 * time.Second,
		DisableKeepAlives:   false,
		DialContext: (&net.Dialer{
			Timeout:   timeout,
			KeepAlive: 30 * time.Second,
		}).DialContext,
	}
	return &http.Client{
		Timeout:   timeout,
		Transport: transport,
	}
}

func doRequest(client *http.Client, url string) (int, float64) {
	start := time.Now()
	resp, err := client.Get(url)
	latency := float64(time.Since(start).Microseconds()) / 1000.0
	if err != nil {
		return 0, latency
	}
	io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
	return resp.StatusCode, latency
}

// -- Preflight ----------------------------------------------------------------

func preflight(client *http.Client, url string) bool {
	fmt.Printf("  Preflight check: %s ... ", url)
	code, lat := doRequest(client, url)
	if code == 0 {
		fmt.Printf("FAILED (unreachable, %.0fms)\n", lat)
		return false
	}
	fmt.Printf("OK (HTTP %d, %.0fms)\n", code, lat)
	return true
}

// -- Stress phase -------------------------------------------------------------

func stress(ctx context.Context, url string, workers int, duration time.Duration, timeout time.Duration, reportInterval time.Duration) *Stats {
	stats := NewStats(10_000)
	client := newHTTPClient(timeout)
	deadline := time.Now().Add(duration)

	var active atomic.Int64
	var wg sync.WaitGroup

	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			active.Add(1)
			defer active.Add(-1)
			for {
				select {
				case <-ctx.Done():
					return
				default:
					if time.Now().After(deadline) {
						return
					}
					code, lat := doRequest(client, url)
					stats.Record(code, lat)
				}
			}
		}()
	}

	// Reporting loop
	start := time.Now()
	ticker := time.NewTicker(reportInterval)
	defer ticker.Stop()

	done := make(chan struct{})
	go func() {
		wg.Wait()
		close(done)
	}()

	for {
		select {
		case <-done:
			return stats
		case <-ctx.Done():
			wg.Wait()
			return stats
		case <-ticker.C:
			elapsed := time.Since(start).Seconds()
			snap := stats.Snapshot()
			rps := float64(snap.Count) / elapsed
			left := time.Until(deadline).Seconds()
			if left < 0 {
				left = 0
			}
			fmt.Printf("  [%4.0fs]  %7d reqs | %6.0f req/s | avg %5.0fms | ok=%d err=%d\n",
				left, snap.Count, rps, snap.AvgMs, snap.OK, snap.Errors)
		}
	}
}

// -- Summary ------------------------------------------------------------------

func printSummary(cycle int, snap Snapshot) {
	if snap.Count == 0 {
		fmt.Printf("  Cycle %d: no requests completed\n\n", cycle)
		return
	}

	pct := float64(snap.OK) / float64(snap.Count) * 100
	sep := strings.Repeat("=", 60)

	fmt.Printf("\n%s\n", sep)
	fmt.Printf("  Cycle %d\n", cycle)
	fmt.Printf("%s\n", sep)
	fmt.Printf("  Requests : %d  (ok=%d  err=%d)\n", snap.Count, snap.OK, snap.Errors)
	fmt.Printf("  Success  : %.1f%%\n", pct)
	fmt.Printf("  Latency  : avg=%.0f  p50=%.0f  p95=%.0f  p99=%.0f ms\n",
		snap.AvgMs, snap.P50Ms, snap.P95Ms, snap.P99Ms)
	fmt.Printf("  Range    : min=%.0f  max=%.0f  stddev=%.0f ms\n",
		snap.MinMs, snap.MaxMs, snap.StddevMs)
	fmt.Printf("%s\n\n", sep)
}

// -- Rest phase ---------------------------------------------------------------

func rest(ctx context.Context, duration time.Duration, reportInterval time.Duration) {
	deadline := time.Now().Add(duration)
	ticker := time.NewTicker(reportInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			fmt.Println()
			return
		case <-ticker.C:
			left := time.Until(deadline)
			if left <= 0 {
				fmt.Println()
				return
			}
			m := int(left.Minutes())
			s := int(left.Seconds()) % 60
			fmt.Printf("\r  Resting... %dm %02ds   ", m, s)
		}
	}
}

// -- ASG status ---------------------------------------------------------------

func asgStatus(asgName, region string) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	query := "AutoScalingGroups[0].{d:DesiredCapacity,r:Instances[?LifecycleState=='InService']|length(@)}"
	cmd := exec.CommandContext(ctx, "aws", "autoscaling", "describe-auto-scaling-groups",
		"--auto-scaling-group-names", asgName,
		"--region", region,
		"--query", query,
		"--output", "json")

	out, err := cmd.Output()
	if err != nil {
		fmt.Printf("  ASG (%s): (unavailable)\n", asgName)
		return
	}

	var info struct {
		D interface{} `json:"d"`
		R interface{} `json:"r"`
	}
	if json.Unmarshal(out, &info) != nil {
		fmt.Printf("  ASG (%s): (unavailable)\n", asgName)
		return
	}

	fmt.Printf("  ASG (%s): %v desired / %v running\n", asgName, info.D, info.R)
}

// -- Results export -----------------------------------------------------------

type CycleResult struct {
	Cycle     int      `json:"cycle"`
	Timestamp string   `json:"timestamp"`
	DurationS int      `json:"duration_s"`
	Workers   int      `json:"workers"`
	Snapshot
}

func exportResults(path string, results []CycleResult) error {
	output := struct {
		GeneratedAt string        `json:"generated_at"`
		Cycles      []CycleResult `json:"cycles"`
	}{
		GeneratedAt: time.Now().UTC().Format(time.RFC3339),
		Cycles:      results,
	}

	data, err := json.MarshalIndent(output, "", "  ")
	if err != nil {
		return err
	}
	err = os.WriteFile(path, data, 0644)
	if err == nil {
		fmt.Printf(">>> Results saved to %s\n", path)
	}
	return err
}

// -- Main ---------------------------------------------------------------------

func main() {
	cfg := loadConfig()

	url := flag.String("url", cfg.DefaultURL, "Target URL")
	workers := flag.Int("workers", cfg.DefaultWorkers, "Number of concurrent workers")
	stressSecs := flag.Int("stress", cfg.DefaultStress, "Stress phase duration (seconds)")
	restSecs := flag.Int("rest", cfg.DefaultRest, "Rest phase duration (seconds)")
	cycles := flag.Int("cycles", 0, "Number of cycles (0 = infinite)")
	timeout := flag.Int("timeout", cfg.DefaultTimeout, "HTTP request timeout (seconds)")
	asgName := flag.String("asg-name", cfg.DefaultASGName, "ASG name for status checks")
	region := flag.String("region", cfg.DefaultRegion, "AWS region")
	output := flag.String("output", "", "Export results to JSON file")
	skipPreflight := flag.Bool("skip-preflight", false, "Skip preflight connectivity check")
	flag.Parse()

	if *url == "" {
		fmt.Println("ERROR: No URL configured. Set DEFAULT_URL in defaults.json or pass -url")
		os.Exit(1)
	}

	sep := strings.Repeat("-", 60)
	fmt.Printf("\n%s\n", sep)
	fmt.Println("  ASG Stress Test (Go)")
	fmt.Printf("%s\n", sep)
	fmt.Printf("  URL     : %s\n", *url)
	fmt.Printf("  Workers : %d\n", *workers)
	fmt.Printf("  Cycle   : %ds stress / %ds rest\n", *stressSecs, *restSecs)
	cycleStr := "inf"
	if *cycles > 0 {
		cycleStr = fmt.Sprintf("%d", *cycles)
	}
	fmt.Printf("  Cycles  : %s\n", cycleStr)
	fmt.Printf("  Pool    : Go net/http (keep-alive, %d max idle conns)\n", 500)
	fmt.Printf("%s\n\n", sep)

	client := newHTTPClient(time.Duration(*timeout) * time.Second)

	if !*skipPreflight {
		if !preflight(client, *url) {
			fmt.Println("ERROR: Preflight failed. Use -skip-preflight to bypass.")
			os.Exit(1)
		}
		fmt.Println()
	}

	asgStatus(*asgName, *region)
	fmt.Println()

	// Handle signals
	ctx, cancel := context.WithCancel(context.Background())
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigCh
		fmt.Println("\n>>> Stopping...")
		cancel()
		// Second signal = force exit
		<-sigCh
		os.Exit(1)
	}()

	stressDur := time.Duration(*stressSecs) * time.Second
	restDur := time.Duration(*restSecs) * time.Second
	reportInterval := time.Duration(cfg.ReportInterval) * time.Second

	var allResults []CycleResult

	for cycle := 1; ; cycle++ {
		if *cycles > 0 && cycle > *cycles {
			break
		}
		if ctx.Err() != nil {
			break
		}

		fmt.Printf(">>> Cycle %d — STRESS (%ds) @ %s\n",
			cycle, *stressSecs, time.Now().Format("15:04:05"))

		stats := stress(ctx, *url, *workers, stressDur, time.Duration(*timeout)*time.Second, reportInterval)
		snap := stats.Snapshot()
		printSummary(cycle, snap)
		asgStatus(*asgName, *region)

		allResults = append(allResults, CycleResult{
			Cycle:     cycle,
			Timestamp: time.Now().UTC().Format(time.RFC3339),
			DurationS: *stressSecs,
			Workers:   *workers,
			Snapshot:  snap,
		})

		if ctx.Err() != nil || (*cycles > 0 && cycle >= *cycles) {
			break
		}

		fmt.Printf(">>> Cycle %d — REST (%ds) @ %s\n",
			cycle, *restSecs, time.Now().Format("15:04:05"))
		rest(ctx, restDur, reportInterval)
		asgStatus(*asgName, *region)
		fmt.Println()
	}

	if *output != "" && len(allResults) > 0 {
		exportResults(*output, allResults)
	}

	fmt.Println(">>> Done.")
}
