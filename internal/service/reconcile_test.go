package service

import (
	"context"
	"errors"
	"net/netip"
	"testing"
)

type fakeDataplane struct {
	state       map[TranslationKey]Translation
	writes      int
	failUpsert  bool
	ignoreWrite bool
}

func (f *fakeDataplane) List(context.Context) ([]Translation, error) {
	var result []Translation
	for _, item := range f.state {
		result = append(result, item)
	}
	return result, nil
}

func (f *fakeDataplane) Upsert(_ context.Context, item Translation) error {
	f.writes++
	if f.failUpsert {
		return errors.New("injected API failure")
	}
	if !f.ignoreWrite {
		f.state[item.Key] = item
	}
	return nil
}

func (f *fakeDataplane) Delete(_ context.Context, key TranslationKey) error {
	f.writes++
	delete(f.state, key)
	return nil
}

func TestReconcileConvergesAfterRepeatedAndFailedEvents(t *testing.T) {
	ctx := context.Background()
	key := TranslationKey{VIP: netip.MustParseAddr("198.19.0.20"), Protocol: UDP, Port: 18080}
	backendA := Backend{Address: netip.MustParseAddr("10.10.2.2"), Port: 18080}
	backendB := Backend{Address: netip.MustParseAddr("10.10.2.3"), Port: 18080}
	want := []Service{{Owner: "test/echo", Key: key, Backends: []Backend{backendB, backendA, backendA}}}
	fake := &fakeDataplane{state: make(map[TranslationKey]Translation), failUpsert: true}
	r := Reconciler{Dataplane: fake}
	if _, err := r.Reconcile(ctx, want); err == nil {
		t.Fatal("partial API failure must be visible")
	}
	fake.failUpsert = false
	changed, err := r.Reconcile(ctx, want)
	if err != nil || changed != 1 {
		t.Fatalf("retry: changed=%d err=%v", changed, err)
	}
	if got := fake.state[key].Backends; len(got) != 2 || got[0] != backendA || got[1] != backendB {
		t.Fatalf("backend sort/dedup: %+v", got)
	}
	changed, err = r.Reconcile(ctx, want)
	if err != nil || changed != 0 || fake.writes != 2 {
		t.Fatalf("duplicate event changed actual state: changed=%d writes=%d err=%v", changed, fake.writes, err)
	}
	want[0].Backends = []Backend{backendA}
	changed, err = r.Reconcile(ctx, want)
	if err != nil || changed != 1 {
		t.Fatalf("backend delete: changed=%d err=%v", changed, err)
	}
	want = nil
	changed, err = r.Reconcile(ctx, want)
	if err != nil || changed != 1 || len(fake.state) != 0 {
		t.Fatalf("Service delete: changed=%d state=%v err=%v", changed, fake.state, err)
	}
}

func TestReconcileRejectsFalseSuccessAndVIPConflict(t *testing.T) {
	ctx := context.Background()
	key := TranslationKey{VIP: netip.MustParseAddr("198.19.0.20"), Protocol: TCP, Port: 18080}
	want := []Service{{Owner: "test/a", Key: key, Backends: []Backend{{Address: netip.MustParseAddr("10.10.2.2"), Port: 18080}}}}
	fake := &fakeDataplane{state: make(map[TranslationKey]Translation), ignoreWrite: true}
	r := Reconciler{Dataplane: fake}
	if _, err := r.Reconcile(ctx, want); err == nil {
		t.Fatal("API success without VPP actual state must fail verification")
	}
	want = append(want, Service{Owner: "test/b", Key: key})
	if _, err := r.Reconcile(ctx, want); err == nil {
		t.Fatal("two Services sharing one VIP/protocol/port must be rejected")
	}
}

func TestStoreSnapshotOwnsBackendSlice(t *testing.T) {
	store := &Store{}
	input := []Service{{Owner: "test/a", Key: TranslationKey{VIP: netip.MustParseAddr("198.19.0.20"), Protocol: UDP, Port: 80}, Backends: []Backend{{Address: netip.MustParseAddr("10.10.2.2"), Port: 8080}}}}
	if _, err := store.Replace(input); err != nil {
		t.Fatal(err)
	}
	input[0].Backends[0].Port = 1
	_, snap := store.Snapshot()
	if snap[0].Backends[0].Port != 8080 {
		t.Fatalf("store aliases caller input: %+v", snap)
	}
	snap[0].Backends[0].Port = 2
	_, snap = store.Snapshot()
	if snap[0].Backends[0].Port != 8080 {
		t.Fatalf("snapshot aliases store: %+v", snap)
	}
}
