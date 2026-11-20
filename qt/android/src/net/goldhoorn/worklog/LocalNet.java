package net.goldhoorn.worklog;

import java.net.InetAddress;
import java.util.Locale;

// Is a server URL on the local network? Used to ask for the LAN permission (PomodoroAlarm) and to decide
// whether credentials may go over plain http (WorklogClient): only to such a host.
final class LocalNet {
    private LocalNet() {
    }

    // localhost, a single-label or .local name, or a private address: RFC 1918, CGNAT 100.64.0.0/10
    // (Tailscale), link-local 169.254/16, loopback, IPv6 loopback, ULA fc00::/7, link-local fe80::/10
    static boolean isLocalHost(String url) {
        try {
            String h = new java.net.URI(url).getHost();
            if (h == null)
                return false;
            h = h.toLowerCase(Locale.ROOT);
            if (h.startsWith("[") && h.endsWith("]"))
                h = h.substring(1, h.length() - 1);
            if (h.indexOf(':') >= 0)
                return isLocalV6(h);
            if (h.equals("localhost") || h.endsWith(".local") || h.indexOf('.') < 0)
                return true;
            return isLocalV4(h);
        } catch (Exception e) {
            return false;
        }
    }

    private static boolean isLocalV4(String h) {
        String[] p = h.split("\\.", -1);
        if (p.length != 4)
            return false;   // a public name
        int[] o = new int[4];
        for (int i = 0; i < 4; i++) {
            if (!p[i].matches("\\d{1,3}"))
                return false;
            o[i] = Integer.parseInt(p[i]);
            if (o[i] > 255)
                return false;
        }
        return o[0] == 10 || o[0] == 127
                || (o[0] == 192 && o[1] == 168)
                || (o[0] == 172 && o[1] >= 16 && o[1] <= 31)
                || (o[0] == 169 && o[1] == 254)
                || (o[0] == 100 && o[1] >= 64 && o[1] <= 127);
    }

    // h is an IPv6 literal (no DNS lookup happens for one)
    private static boolean isLocalV6(String h) throws Exception {
        int zone = h.indexOf('%');
        byte[] a = InetAddress.getByName(zone < 0 ? h : h.substring(0, zone)).getAddress();
        if (a.length == 4)   // an IPv4-mapped address comes back as IPv4
            return isLocalV4((a[0] & 255) + "." + (a[1] & 255) + "." + (a[2] & 255) + "." + (a[3] & 255));
        boolean loopback = true;
        for (int i = 0; i < 15; i++)
            loopback &= a[i] == 0;
        loopback &= a[15] == 1;
        return loopback
                || (a[0] & 0xFE) == 0xFC                              // fc00::/7
                || ((a[0] & 255) == 0xFE && (a[1] & 0xC0) == 0x80);   // fe80::/10
    }
}
