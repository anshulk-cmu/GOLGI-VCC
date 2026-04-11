package function

import (
	"encoding/json"
	"fmt"
	"math/rand"
	"net/http"
	"regexp"
	"strings"
	"time"

	handler "github.com/openfaas/templates-sdk/go-http"
)

var ipPattern = regexp.MustCompile(`\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}`)
var levelPattern = regexp.MustCompile(`ERROR|WARN|CRITICAL`)

// Handle processes log lines: generates synthetic logs, filters by severity, anonymizes IPs.
func Handle(req handler.Request) (handler.Response, error) {
	// Generate synthetic log data (1000 lines)
	logLines := generateLogLines(1000)

	// CPU-intensive: regex matching on each line
	var filtered []string
	for _, line := range logLines {
		if levelPattern.MatchString(line) {
			sanitized := anonymizeIPs(line)
			filtered = append(filtered, sanitized)
		}
	}

	sampleSize := 5
	if len(filtered) < sampleSize {
		sampleSize = len(filtered)
	}

	result := map[string]interface{}{
		"total_lines":    len(logLines),
		"filtered_count": len(filtered),
		"sample":         filtered[:sampleSize],
	}

	body, _ := json.Marshal(result)

	return handler.Response{
		Body:       body,
		StatusCode: http.StatusOK,
		Header: http.Header{
			"Content-Type": []string{"application/json"},
		},
	}, nil
}

func generateLogLines(count int) []string {
	levels := []string{"DEBUG", "INFO", "WARN", "ERROR", "CRITICAL"}
	services := []string{"api-gateway", "auth-service", "data-pipeline", "cache-layer", "scheduler"}
	messages := []string{
		"Request processed successfully",
		"Connection timeout after 30s",
		"Failed to authenticate user",
		"Cache miss for key",
		"Disk usage above threshold",
		"Memory allocation failed",
		"Rate limit exceeded",
		"Database connection pool exhausted",
	}

	rng := rand.New(rand.NewSource(time.Now().UnixNano()))
	lines := make([]string, count)
	for i := 0; i < count; i++ {
		ts := time.Now().Add(-time.Duration(rng.Intn(3600)) * time.Second).Format(time.RFC3339)
		ip := fmt.Sprintf("%d.%d.%d.%d", rng.Intn(256), rng.Intn(256), rng.Intn(256), rng.Intn(256))
		level := levels[rng.Intn(len(levels))]
		svc := services[rng.Intn(len(services))]
		msg := messages[rng.Intn(len(messages))]
		lines[i] = fmt.Sprintf("%s %s [%s] %s: %s", ts, ip, level, svc, msg)
	}
	return lines
}

func anonymizeIPs(line string) string {
	return ipPattern.ReplaceAllStringFunc(line, func(ip string) string {
		parts := strings.Split(ip, ".")
		if len(parts) == 4 {
			return parts[0] + "." + parts[1] + ".xxx.xxx"
		}
		return "xxx.xxx.xxx.xxx"
	})
}
