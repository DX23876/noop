package com.noop.ai

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #321 / #187: the Custom (local-LLM) provider locality classifier — plain http:// is allowed ONLY to a
 * host on the device or its private LAN, so a public cleartext endpoint can never egress. This is the
 * byte-parity REFERENCE for the Swift twin `AIProvider.isPrivateLANOrLoopback` (Swift was missing the
 * guard entirely — #321). Same fixtures must classify identically on both platforms.
 */
class CustomUrlLocalityTest {

    private fun local(h: String) =
        assertTrue("$h should be treated as local/LAN", AiCoach.isPrivateLanOrLoopback(h))

    private fun public_(h: String) =
        assertFalse("$h should be treated as PUBLIC (no cleartext)", AiCoach.isPrivateLanOrLoopback(h))

    @Test
    fun `loopback and LAN hosts are local`() {
        listOf(
            "localhost", "foo.localhost",
            "127.0.0.1", "127.255.255.254",
            "10.0.0.5", "10.0.2.2",              // 10/8 incl. the Android-emulator host alias
            "172.16.0.1", "172.31.255.254",      // 172.16/12
            "192.168.1.100",                     // 192.168/16
            "169.254.10.20",                     // link-local
            "::1", "[::1]",                       // IPv6 loopback (bracketed or not)
            "fc00::1", "fd12:3456::1", "fe80::abcd",  // ULA / link-local literals
            "nas.local", "printer.local",        // mDNS
        ).forEach(::local)
    }

    @Test
    fun `public hosts are rejected — incl the fc-name and 172-edge traps`() {
        listOf(
            "api.openai.com", "example.com",
            "8.8.8.8", "1.2.3.4",
            "172.15.0.1", "172.32.0.1",          // just outside 172.16-31
            "fclient.evil.com", "fdn.example.com",  // public NAMES starting fc/fd — must NOT be ULA
            "fe80.evil.com",                     // public name starting fe80 (not an IPv6 literal)
            "2001:4860:4860::8888",              // public IPv6 literal
            "local", ".local",                   // bare mDNS suffix must not pass
            "",                                  // empty
        ).forEach(::public_)
    }
}
