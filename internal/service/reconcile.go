package service

import (
	"context"
	"fmt"
	"slices"
)

type Translation struct {
	Key      TranslationKey
	Backends []Backend
}

// Dataplane 返回本项目隔离 VIP 范围内的 actual CNAT translation。
type Dataplane interface {
	List(context.Context) ([]Translation, error)
	Upsert(context.Context, Translation) error
	Delete(context.Context, TranslationKey) error
}

type Reconciler struct {
	Dataplane Dataplane
}

func (r Reconciler) Reconcile(ctx context.Context, desired []Service) (int, error) {
	if r.Dataplane == nil {
		return 0, fmt.Errorf("Dataplane 未配置")
	}
	normalized, err := normalize(desired)
	if err != nil {
		return 0, err
	}
	actual, err := r.Dataplane.List(ctx)
	if err != nil {
		return 0, fmt.Errorf("查询 VPP actual translation: %w", err)
	}
	want := make(map[TranslationKey]Translation)
	for _, item := range normalized {
		if len(item.Backends) != 0 {
			want[item.Key] = Translation{Key: item.Key, Backends: item.Backends}
		}
	}
	have := make(map[TranslationKey]Translation)
	for _, item := range actual {
		if !IsManagedVIP(item.Key.VIP) {
			continue
		}
		if err := item.Key.Validate(); err != nil {
			return 0, fmt.Errorf("VPP actual translation 无效: %w", err)
		}
		if _, duplicate := have[item.Key]; duplicate {
			return 0, fmt.Errorf("VPP actual translation 重复: %v", item.Key)
		}
		have[item.Key] = item
	}
	changed := 0
	for _, item := range normalized {
		translation, exists := want[item.Key]
		if !exists {
			continue
		}
		current, found := have[item.Key]
		if found && slices.Equal(current.Backends, translation.Backends) {
			continue
		}
		if err := r.Dataplane.Upsert(ctx, translation); err != nil {
			return changed, fmt.Errorf("写入 %s/%s:%d: %w", item.Key.VIP, item.Key.Protocol, item.Key.Port, err)
		}
		changed++
	}
	var remove []TranslationKey
	for key := range have {
		if _, exists := want[key]; exists {
			continue
		}
		remove = append(remove, key)
	}
	slices.SortFunc(remove, func(a, b TranslationKey) int {
		if c := a.VIP.Compare(b.VIP); c != 0 {
			return c
		}
		if a.Port != b.Port {
			return int(a.Port) - int(b.Port)
		}
		if a.Protocol < b.Protocol {
			return -1
		}
		if a.Protocol > b.Protocol {
			return 1
		}
		return 0
	})
	for _, key := range remove {
		if err := r.Dataplane.Delete(ctx, key); err != nil {
			return changed, fmt.Errorf("删除 %s/%s:%d: %w", key.VIP, key.Protocol, key.Port, err)
		}
		changed++
	}
	verified, err := r.Dataplane.List(ctx)
	if err != nil {
		return changed, fmt.Errorf("写入后复查 VPP actual translation: %w", err)
	}
	observed := make(map[TranslationKey]Translation)
	for _, item := range verified {
		if IsManagedVIP(item.Key.VIP) {
			observed[item.Key] = item
		}
	}
	if len(observed) != len(want) {
		return changed, fmt.Errorf("VPP actual translation 数量不匹配: want=%d got=%d", len(want), len(observed))
	}
	for key, expected := range want {
		item, exists := observed[key]
		if !exists || !slices.Equal(item.Backends, expected.Backends) {
			return changed, fmt.Errorf("VPP actual translation 未收敛: %s/%s:%d", key.VIP, key.Protocol, key.Port)
		}
	}
	return changed, nil
}
