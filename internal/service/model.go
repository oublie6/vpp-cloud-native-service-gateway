package service

import (
	"fmt"
	"net/netip"
	"slices"
)

// Goal 003+ 使用 198.19.0.0/16，避免接管 Goal 002 的 198.18.0.10。
var vipRange = netip.MustParsePrefix("198.19.0.0/16")

type Protocol string

const (
	TCP Protocol = "TCP"
	UDP Protocol = "UDP"
)

type Backend struct {
	Address netip.Addr
	Port    uint16
}

type TranslationKey struct {
	VIP      netip.Addr
	Protocol Protocol
	Port     uint16
}

type Service struct {
	Owner    string
	Key      TranslationKey
	Backends []Backend
}

func (k TranslationKey) Validate() error {
	if !k.VIP.Is4() || !vipRange.Contains(k.VIP) {
		return fmt.Errorf("VIP %s 不在隔离网段 %s", k.VIP, vipRange)
	}
	if k.Protocol != TCP && k.Protocol != UDP {
		return fmt.Errorf("不支持协议 %q", k.Protocol)
	}
	if k.Port == 0 {
		return fmt.Errorf("VIP port 必须非零")
	}
	return nil
}

func normalize(in []Service) ([]Service, error) {
	out := make([]Service, 0, len(in))
	keys := make(map[TranslationKey]string)
	for _, item := range in {
		if item.Owner == "" {
			return nil, fmt.Errorf("Service owner 不能为空")
		}
		if err := item.Key.Validate(); err != nil {
			return nil, fmt.Errorf("%s: %w", item.Owner, err)
		}
		if previous, found := keys[item.Key]; found {
			return nil, fmt.Errorf("VIP %s/%s:%d 同时由 %s 与 %s 声明", item.Key.VIP, item.Key.Protocol, item.Key.Port, previous, item.Owner)
		}
		keys[item.Key] = item.Owner
		copyItem := Service{Owner: item.Owner, Key: item.Key}
		seen := make(map[Backend]bool)
		for _, backend := range item.Backends {
			if !backend.Address.Is4() || backend.Address.IsUnspecified() || backend.Address.IsMulticast() || backend.Port == 0 {
				return nil, fmt.Errorf("%s: 无效 backend %s:%d", item.Owner, backend.Address, backend.Port)
			}
			if !seen[backend] {
				copyItem.Backends = append(copyItem.Backends, backend)
				seen[backend] = true
			}
		}
		slices.SortFunc(copyItem.Backends, func(a, b Backend) int {
			if c := a.Address.Compare(b.Address); c != 0 {
				return c
			}
			return int(a.Port) - int(b.Port)
		})
		out = append(out, copyItem)
	}
	slices.SortFunc(out, func(a, b Service) int {
		if c := a.Key.VIP.Compare(b.Key.VIP); c != 0 {
			return c
		}
		if a.Key.Port != b.Key.Port {
			return int(a.Key.Port) - int(b.Key.Port)
		}
		if a.Key.Protocol < b.Key.Protocol {
			return -1
		}
		if a.Key.Protocol > b.Key.Protocol {
			return 1
		}
		return 0
	})
	return out, nil
}

func IsManagedVIP(addr netip.Addr) bool { return vipRange.Contains(addr) }
