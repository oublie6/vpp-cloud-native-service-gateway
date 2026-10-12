package kube

import (
	"errors"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestMetricsReflectFailureAndRecovery(t *testing.T) {
	controller := &Controller{}
	controller.attempts.Add(2)
	controller.failures.Add(1)
	controller.changes.Add(3)
	controller.recordResult(errors.New("VPP socket missing"))
	status := controller.Status()
	if status.LastError != "VPP socket missing" || status.LastFailure.IsZero() {
		t.Fatalf("failure status missing: %+v", status)
	}
	controller.recordResult(nil)
	status = controller.Status()
	if status.LastError != "" || status.LastSuccess.IsZero() {
		t.Fatalf("recovery status missing: %+v", status)
	}
	response := httptest.NewRecorder()
	MetricsHandler(controller).ServeHTTP(response, httptest.NewRequest("GET", "/metrics", nil))
	if response.Code != 200 {
		t.Fatalf("metrics status: %d", response.Code)
	}
	for _, line := range []string{
		"vpp_gateway_reconcile_attempts_total 2",
		"vpp_gateway_reconcile_failures_total 1",
		"vpp_gateway_reconcile_changes_total 3",
	} {
		if !strings.Contains(response.Body.String(), line) {
			t.Fatalf("metrics 缺少 %q: %s", line, response.Body.String())
		}
	}
	response = httptest.NewRecorder()
	MetricsHandler(controller).ServeHTTP(response, httptest.NewRequest("GET", "/status", nil))
	if response.Code != 200 || !strings.Contains(response.Body.String(), "lastSuccess") {
		t.Fatalf("status response: %d %s", response.Code, response.Body.String())
	}
}
