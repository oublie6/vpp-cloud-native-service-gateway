package kube

import (
	"testing"

	corev1 "k8s.io/api/core/v1"
	discoveryv1 "k8s.io/api/discovery/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
)

func boolPtr(v bool) *bool       { return &v }
func int32Ptr(v int32) *int32    { return &v }
func stringPtr(v string) *string { return &v }

func TestBuildDesiredJoinsSlicesAndFiltersEndpoints(t *testing.T) {
	svc := &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{Namespace: "test", Name: "echo", UID: types.UID("new"), Annotations: map[string]string{VIPAnnotation: "198.19.0.20"}},
		Spec:       corev1.ServiceSpec{ClusterIP: "10.96.0.20", Ports: []corev1.ServicePort{{Name: "udp", Protocol: corev1.ProtocolUDP, Port: 18080}}},
	}
	slice := &discoveryv1.EndpointSlice{
		ObjectMeta:  metav1.ObjectMeta{Namespace: "test", Name: "echo-a", Labels: map[string]string{discoveryv1.LabelServiceName: "echo"}},
		AddressType: discoveryv1.AddressTypeIPv4,
		Ports:       []discoveryv1.EndpointPort{{Name: stringPtr("udp"), Protocol: ptrProtocol(corev1.ProtocolUDP), Port: int32Ptr(18081)}},
		Endpoints: []discoveryv1.Endpoint{
			{Addresses: []string{"10.10.2.2"}},
			{Addresses: []string{"10.10.2.3"}, Conditions: discoveryv1.EndpointConditions{Ready: boolPtr(false)}},
			{Addresses: []string{"10.10.2.4"}, Conditions: discoveryv1.EndpointConditions{Terminating: boolPtr(true)}},
		},
	}
	other := slice.DeepCopy()
	other.Name = "echo-b"
	other.Endpoints = []discoveryv1.Endpoint{{Addresses: []string{"10.10.2.5"}}}
	stale := slice.DeepCopy()
	stale.Name = "echo-stale"
	stale.OwnerReferences = []metav1.OwnerReference{{Kind: "Service", Name: "echo", UID: types.UID("old")}}
	stale.Endpoints = []discoveryv1.Endpoint{{Addresses: []string{"10.10.2.6"}}}
	ordinary := svc.DeepCopy()
	ordinary.Name = "ordinary"
	ordinary.Annotations = nil

	want, err := BuildDesired([]*corev1.Service{svc, ordinary}, []*discoveryv1.EndpointSlice{slice, other, stale})
	if err != nil {
		t.Fatal(err)
	}
	if len(want) != 1 || len(want[0].Backends) != 2 || want[0].Backends[0].Address.String() != "10.10.2.2" || want[0].Backends[1].Address.String() != "10.10.2.5" || want[0].Backends[0].Port != 18081 {
		t.Fatalf("unexpected desired state: %+v", want)
	}
}

func TestBuildDesiredRejectsKubeProxyVIPConflict(t *testing.T) {
	base := &corev1.Service{ObjectMeta: metav1.ObjectMeta{Namespace: "test", Name: "bad", Annotations: map[string]string{VIPAnnotation: "198.19.0.20"}}, Spec: corev1.ServiceSpec{ClusterIP: "10.96.0.20", Ports: []corev1.ServicePort{{Port: 80}}}}
	for name, change := range map[string]func(*corev1.Service){
		"ClusterIP":      func(s *corev1.Service) { s.Spec.ClusterIP = "198.19.0.20" },
		"ClusterIPs":     func(s *corev1.Service) { s.Spec.ClusterIPs = []string{"10.96.0.20", "198.19.0.20"} },
		"ExternalIPs":    func(s *corev1.Service) { s.Spec.ExternalIPs = []string{"198.19.0.20"} },
		"LoadBalancerIP": func(s *corev1.Service) { s.Spec.LoadBalancerIP = "198.19.0.20" },
		"LoadBalancerIngress": func(s *corev1.Service) {
			s.Status.LoadBalancer.Ingress = []corev1.LoadBalancerIngress{{IP: "198.19.0.20"}}
		},
	} {
		t.Run(name, func(t *testing.T) {
			svc := base.DeepCopy()
			change(svc)
			if _, err := BuildDesired([]*corev1.Service{svc}, nil); err == nil {
				t.Fatal("Kubernetes owned VIP must be rejected")
			}
		})
	}
}

func ptrProtocol(v corev1.Protocol) *corev1.Protocol { return &v }
