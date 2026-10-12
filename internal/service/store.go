package service

import "sync"

// Store 保存 informer 缓存归一化后的最新快照，不直接向 VPP 写状态。
type Store struct {
	mu         sync.RWMutex
	generation uint64
	services   []Service
}

func (s *Store) Replace(next []Service) (uint64, error) {
	normalized, err := normalize(next)
	if err != nil {
		return 0, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.services = normalized
	s.generation++
	return s.generation, nil
}

func (s *Store) Snapshot() (uint64, []Service) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]Service, len(s.services))
	for i, item := range s.services {
		out[i] = item
		out[i].Backends = append([]Backend(nil), item.Backends...)
	}
	return s.generation, out
}
