//go:build android && cgo

package tun

import "C"
import (
	"github.com/metacubex/mihomo/constant"
	LC "github.com/metacubex/mihomo/listener/config"
	"github.com/metacubex/mihomo/listener/sing_tun"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
	"net"
	"net/netip"
	"strings"
)

func Start(fd int, config Options) *sing_tun.Listener {
	var prefix4 []netip.Prefix
	var prefix6 []netip.Prefix
	tunStack, ok := constant.StackTypeMapping[strings.ToLower(config.Stack)]
	if !ok {
		tunStack = constant.TunSystem
	}
	for _, a := range strings.Split(config.Address, ",") {
		a = strings.TrimSpace(a)
		if len(a) == 0 {
			continue
		}
		prefix, err := netip.ParsePrefix(a)
		if err != nil {
			log.Errorln("TUN:", err)
			return nil
		}
		if prefix.Addr().Is4() {
			prefix4 = append(prefix4, prefix)
		} else {
			prefix6 = append(prefix6, prefix)
		}
	}

	var dnsHijack []string
	for _, d := range strings.Split(config.DNS, ",") {
		d = strings.TrimSpace(d)
		if len(d) == 0 {
			continue
		}
		dnsHijack = append(dnsHijack, net.JoinHostPort(d, "53"))
	}

	options := LC.Tun{
		Enable:                 true,
		Device:                 "FlClash",
		Stack:                  tunStack,
		DNSHijack:              dnsHijack,
		AutoRoute:              false,
		AutoDetectInterface:    false,
		Inet4Address:           prefix4,
		Inet6Address:           prefix6,
		MTU:                    config.MTU,
		FileDescriptor:         fd,
		DisableICMPForwarding:  config.DisableICMPForwarding,
		EndpointIndependentNat: config.EndpointIndependentNAT,
	}

	listener, err := sing_tun.New(options, tunnel.Tunnel)

	if err != nil {
		log.Errorln("TUN:", err)
		return nil
	}

	return listener
}
