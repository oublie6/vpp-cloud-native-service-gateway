package kube

import (
	"encoding/json"
	"fmt"
	"net/http"
	"time"
)

// MetricsHandler 只提供只读状态；监听地址由调用方限制为 loopback。
func MetricsHandler(controller *Controller) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /metrics", func(w http.ResponseWriter, _ *http.Request) {
		status := controller.Status()
		w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
		fmt.Fprintf(w, "# TYPE vpp_gateway_reconcile_attempts_total counter\nvpp_gateway_reconcile_attempts_total %d\n", status.Counters.Attempts)
		fmt.Fprintf(w, "# TYPE vpp_gateway_reconcile_failures_total counter\nvpp_gateway_reconcile_failures_total %d\n", status.Counters.Failures)
		fmt.Fprintf(w, "# TYPE vpp_gateway_reconcile_changes_total counter\nvpp_gateway_reconcile_changes_total %d\n", status.Counters.Changes)
		fmt.Fprintf(w, "# TYPE vpp_gateway_last_success_unixtime gauge\nvpp_gateway_last_success_unixtime %d\n", unixTime(status.LastSuccess))
		fmt.Fprintf(w, "# TYPE vpp_gateway_last_failure_unixtime gauge\nvpp_gateway_last_failure_unixtime %d\n", unixTime(status.LastFailure))
	})
	mux.HandleFunc("GET /status", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(controller.Status()); err != nil {
			return
		}
	})
	return mux
}

func unixTime(value time.Time) int64 {
	if value.IsZero() {
		return 0
	}
	return value.Unix()
}
