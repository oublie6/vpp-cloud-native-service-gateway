package vppcnat

import (
	"context"
	"fmt"
	"io"
	"net/netip"
	"slices"

	"github.com/oublie6/vpp-cloud-native-service-gateway/internal/service"
	"go.fd.io/govpp"
	"go.fd.io/govpp/binapi/cnat"
	"go.fd.io/govpp/binapi/interface_types"
	"go.fd.io/govpp/binapi/ip_types"
	"go.fd.io/govpp/core"
)

type Client struct {
	conn *core.Connection
	api  cnat.RPCService
}

func Connect(socket string) (*Client, error) {
	conn, err := govpp.Connect(socket)
	if err != nil {
		return nil, fmt.Errorf("连接 VPP Binary API %s: %w", socket, err)
	}
	channel, err := conn.NewAPIChannel()
	if err != nil {
		conn.Disconnect()
		return nil, fmt.Errorf("创建 GoVPP channel: %w", err)
	}
	err = channel.CheckCompatiblity(
		&cnat.CnatTranslationDump{}, &cnat.CnatTranslationDetails{},
		&cnat.CnatTranslationUpdate{}, &cnat.CnatTranslationUpdateReply{},
		&cnat.CnatTranslationDel{}, &cnat.CnatTranslationDelReply{},
	)
	channel.Close()
	if err != nil {
		conn.Disconnect()
		return nil, fmt.Errorf("CNAT Binary API schema 不兼容: %w", err)
	}
	return &Client{conn: conn, api: cnat.NewServiceClient(conn)}, nil
}

func (c *Client) Close() { c.conn.Disconnect() }

func protocolFromAPI(proto ip_types.IPProto) (service.Protocol, bool) {
	switch proto {
	case ip_types.IP_API_PROTO_TCP:
		return service.TCP, true
	case ip_types.IP_API_PROTO_UDP:
		return service.UDP, true
	default:
		return "", false
	}
}

func protocolToAPI(proto service.Protocol) (ip_types.IPProto, error) {
	switch proto {
	case service.TCP:
		return ip_types.IP_API_PROTO_TCP, nil
	case service.UDP:
		return ip_types.IP_API_PROTO_UDP, nil
	default:
		return 0, fmt.Errorf("不支持 CNAT 协议 %q", proto)
	}
}

func (c *Client) dump(ctx context.Context) ([]cnat.CnatTranslation, error) {
	stream, err := c.api.CnatTranslationDump(ctx, &cnat.CnatTranslationDump{})
	if err != nil {
		return nil, fmt.Errorf("CnatTranslationDump: %w", err)
	}
	defer stream.Close()
	var result []cnat.CnatTranslation
	for {
		item, err := stream.Recv()
		if err == io.EOF {
			return result, nil
		}
		if err != nil {
			return nil, fmt.Errorf("CnatTranslationDump 读取: %w", err)
		}
		result = append(result, item.Translation)
	}
}

func (c *Client) List(ctx context.Context) ([]service.Translation, error) {
	raw, err := c.dump(ctx)
	if err != nil {
		return nil, err
	}
	var result []service.Translation
	for _, item := range raw {
		vip, err := netip.ParseAddr(item.Vip.Addr.String())
		if err != nil || !service.IsManagedVIP(vip) {
			continue
		}
		proto, ok := protocolFromAPI(item.IPProto)
		if !ok {
			return nil, fmt.Errorf("受管 VIP %s 的 VPP 协议不支持: %s", vip, item.IPProto)
		}
		entry := service.Translation{Key: service.TranslationKey{VIP: vip, Protocol: proto, Port: item.Vip.Port}}
		for _, path := range item.Paths {
			addr, err := netip.ParseAddr(path.DstEp.Addr.String())
			if err != nil {
				return nil, fmt.Errorf("VIP %s 的 backend 地址无效: %w", vip, err)
			}
			entry.Backends = append(entry.Backends, service.Backend{Address: addr, Port: path.DstEp.Port})
		}
		slices.SortFunc(entry.Backends, func(a, b service.Backend) int {
			if c := a.Address.Compare(b.Address); c != 0 {
				return c
			}
			return int(a.Port) - int(b.Port)
		})
		result = append(result, entry)
	}
	return result, nil
}

func endpoint(ip netip.Addr, port uint16) (cnat.CnatEndpoint, error) {
	address, err := ip_types.ParseAddress(ip.String())
	if err != nil || address.Af != ip_types.ADDRESS_IP4 {
		return cnat.CnatEndpoint{}, fmt.Errorf("无效 IPv4 endpoint %s:%d: %v", ip, port, err)
	}
	return cnat.CnatEndpoint{Addr: address, Port: port, SwIfIndex: interface_types.InterfaceIndex(^uint32(0))}, nil
}

func (c *Client) Upsert(ctx context.Context, item service.Translation) error {
	if err := item.Key.Validate(); err != nil {
		return err
	}
	proto, err := protocolToAPI(item.Key.Protocol)
	if err != nil {
		return err
	}
	vip, err := endpoint(item.Key.VIP, item.Key.Port)
	if err != nil {
		return err
	}
	source, err := endpoint(netip.IPv4Unspecified(), 0)
	if err != nil {
		return err
	}
	paths := make([]cnat.CnatEndpointTuple, 0, len(item.Backends))
	for _, backend := range item.Backends {
		destination, err := endpoint(backend.Address, backend.Port)
		if err != nil {
			return err
		}
		paths = append(paths, cnat.CnatEndpointTuple{DstEp: destination, SrcEp: source})
	}
	if len(paths) == 0 {
		return fmt.Errorf("VIP %s/%s:%d 不能写入零 backend translation", item.Key.VIP, item.Key.Protocol, item.Key.Port)
	}
	if _, err := c.api.CnatTranslationUpdate(ctx, &cnat.CnatTranslationUpdate{Translation: cnat.CnatTranslation{
		Vip: vip, IPProto: proto, IsRealIP: 0, LbType: cnat.CNAT_LB_TYPE_MAGLEV, Paths: paths,
	}}); err != nil {
		return fmt.Errorf("CnatTranslationUpdate %s/%s:%d: %w", item.Key.VIP, item.Key.Protocol, item.Key.Port, err)
	}
	return nil
}

func (c *Client) Delete(ctx context.Context, key service.TranslationKey) error {
	if err := key.Validate(); err != nil {
		return err
	}
	proto, err := protocolToAPI(key.Protocol)
	if err != nil {
		return err
	}
	translations, err := c.dump(ctx)
	if err != nil {
		return err
	}
	for _, item := range translations {
		if item.Vip.Addr.String() == key.VIP.String() && item.Vip.Port == key.Port && item.IPProto == proto {
			if _, err := c.api.CnatTranslationDel(ctx, &cnat.CnatTranslationDel{ID: item.ID}); err != nil {
				return fmt.Errorf("CnatTranslationDel %s/%s:%d id=%d: %w", key.VIP, key.Protocol, key.Port, item.ID, err)
			}
			return nil
		}
	}
	return nil
}
