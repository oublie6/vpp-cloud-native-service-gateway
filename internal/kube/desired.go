package kube

import (
	"fmt"
	"net/netip"
	"strconv"

	"github.com/oublie6/vpp-cloud-native-service-gateway/internal/service"
	corev1 "k8s.io/api/core/v1"
	discoveryv1 "k8s.io/api/discovery/v1"
)

const VIPAnnotation = "vpp-gateway.example/test-vip"

// BuildDesired 只读取 informer cache snapshot；不会访问 VPP 或 Kubernetes API。
func BuildDesired(services []*corev1.Service, slices []*discoveryv1.EndpointSlice) ([]service.Service, error) {
	byService := make(map[string][]*discoveryv1.EndpointSlice)
	for _, slice := range slices {
		if slice.AddressType != discoveryv1.AddressTypeIPv4 {
			continue
		}
		name := slice.Labels[discoveryv1.LabelServiceName]
		if name == "" {
			continue
		}
		key := slice.Namespace + "/" + name
		byService[key] = append(byService[key], slice)
	}
	var desired []service.Service
	for _, svc := range services {
		vipText := svc.Annotations[VIPAnnotation]
		if vipText == "" {
			continue
		}
		vip, err := netip.ParseAddr(vipText)
		if err != nil || !service.IsManagedVIP(vip) {
			return nil, fmt.Errorf("Service %s/%s 的 %s=%q 不是 Goal 003 隔离 VIP", svc.Namespace, svc.Name, VIPAnnotation, vipText)
		}
		if svc.Spec.Type == corev1.ServiceTypeExternalName || svc.Spec.ClusterIP == vipText {
			return nil, fmt.Errorf("Service %s/%s 的 VIP 与 Kubernetes Service ownership 冲突", svc.Namespace, svc.Name)
		}
		for _, clusterIP := range svc.Spec.ClusterIPs {
			if clusterIP == vipText {
				return nil, fmt.Errorf("Service %s/%s 的 VIP 同时存在于 ClusterIPs", svc.Namespace, svc.Name)
			}
		}
		for _, external := range svc.Spec.ExternalIPs {
			if external == vipText {
				return nil, fmt.Errorf("Service %s/%s 的 VIP 同时存在于 ExternalIPs", svc.Namespace, svc.Name)
			}
		}
		if svc.Spec.LoadBalancerIP == vipText {
			return nil, fmt.Errorf("Service %s/%s 的 VIP 同时是 LoadBalancerIP", svc.Namespace, svc.Name)
		}
		for _, ingress := range svc.Status.LoadBalancer.Ingress {
			if ingress.IP == vipText {
				return nil, fmt.Errorf("Service %s/%s 的 VIP 同时是 LoadBalancer ingress", svc.Namespace, svc.Name)
			}
		}
		if len(svc.Spec.Ports) == 0 {
			return nil, fmt.Errorf("Service %s/%s 没有端口", svc.Namespace, svc.Name)
		}
		for _, port := range svc.Spec.Ports {
			proto, err := protocol(port.Protocol)
			if err != nil {
				return nil, fmt.Errorf("Service %s/%s port %s: %w", svc.Namespace, svc.Name, port.Name, err)
			}
			if port.Port < 1 || port.Port > 65535 {
				return nil, fmt.Errorf("Service %s/%s port %s: VIP port 无效 %d", svc.Namespace, svc.Name, port.Name, port.Port)
			}
			owner := svc.Namespace + "/" + svc.Name + "/" + string(svc.UID) + "/" + port.Name + "/" + strconv.Itoa(int(port.Port))
			item := service.Service{Owner: owner, Key: service.TranslationKey{VIP: vip, Protocol: proto, Port: uint16(port.Port)}}
			for _, slice := range byService[svc.Namespace+"/"+svc.Name] {
				if hasMismatchedServiceOwner(slice, svc) {
					continue
				}
				backendPort, found := matchPort(slice.Ports, port)
				if !found {
					continue
				}
				for _, endpoint := range slice.Endpoints {
					if endpoint.Conditions.Ready != nil && !*endpoint.Conditions.Ready ||
						endpoint.Conditions.Serving != nil && !*endpoint.Conditions.Serving ||
						endpoint.Conditions.Terminating != nil && *endpoint.Conditions.Terminating {
						continue
					}
					for _, address := range endpoint.Addresses {
						ip, err := netip.ParseAddr(address)
						if err != nil || !ip.Is4() {
							return nil, fmt.Errorf("EndpointSlice %s/%s 的地址 %q 无效", slice.Namespace, slice.Name, address)
						}
						item.Backends = append(item.Backends, service.Backend{Address: ip, Port: backendPort})
					}
				}
			}
			desired = append(desired, item)
		}
	}
	return desired, nil
}

func protocol(p corev1.Protocol) (service.Protocol, error) {
	switch p {
	case "", corev1.ProtocolTCP:
		return service.TCP, nil
	case corev1.ProtocolUDP:
		return service.UDP, nil
	default:
		return "", fmt.Errorf("不支持 Kubernetes 协议 %q", p)
	}
}

func matchPort(ports []discoveryv1.EndpointPort, target corev1.ServicePort) (uint16, bool) {
	for _, port := range ports {
		name := ""
		if port.Name != nil {
			name = *port.Name
		}
		proto := corev1.ProtocolTCP
		if port.Protocol != nil {
			proto = *port.Protocol
		}
		serviceProto := target.Protocol
		if serviceProto == "" {
			serviceProto = corev1.ProtocolTCP
		}
		if name == target.Name && proto == serviceProto && port.Port != nil && *port.Port > 0 && *port.Port <= 65535 {
			return uint16(*port.Port), true
		}
	}
	return 0, false
}

func hasMismatchedServiceOwner(slice *discoveryv1.EndpointSlice, svc *corev1.Service) bool {
	for _, owner := range slice.OwnerReferences {
		if owner.Kind == "Service" && owner.Name == svc.Name && owner.UID != svc.UID {
			return true
		}
	}
	return false
}
