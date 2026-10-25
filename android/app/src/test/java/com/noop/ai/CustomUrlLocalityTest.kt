package com.noop.ai

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #321 / #187: the Custom (local-LLM) provider cleartext classifier. Android's XML policy cannot
 * express RFC1918/link-local CIDR ranges, so network-security-config permits platform cleartext
 * and this guard prevents public cleartext egress for arbitrary Custom URLs.
 */
class CustomUrlLocalityTest {

    private fun cleartextAllowed(h: String) =
        assertTrue("$h should be allowed for Android cleartext", AiCoach.isPrivateLanOrLoopback(h))

    private fun cleartextBlocked(h: String) =
        assertFalse("$h should require HTTPS", AiCoach.isPrivateLanOrLoopback(h))

    @Test
    fun `local and private LAN hosts permit cleartext`() {
        listOf(
            "localhost", "foo.localhost",
            "127.0.0.1", "127.255.255.254",
            "10.0.2.2", "10.0.0.5",             // Android-emulator host alias + RFC1918
            "172.16.0.1", "172.31.255.254",
            "192.168.1.100",
            "169.254.10.20",
            "::1", "[::1]",
            "fc00::1", "fd12:3456::1", "fe80::abcd",
            "nas.local", "printer.local",        // mDNS
        ).forEach(::cleartextAllowed)
    }

    @Test
    fun `public and malformed local hosts require HTTPS`() {
        listOf(
            "api.openai.com", "example.com",
            "8.8.8.8", "1.2.3.4",
            "172.15.255.255", "172.32.0.0",
            "169.253.255.255",
            "fclient.evil.com", "fdn.example.com",
            "fe80.evil.com",
            "2001:4860:4860::8888",              // public IPv6 literal
            "local", ".local",                   // bare mDNS suffix must not pass
            "",                                  // empty
        ).forEach(::cleartextBlocked)
    }

    @Test
    fun `built in cloud provider endpoints are https only`() {
        AiProvider.entries
            .filter { it != AiProvider.CUSTOM }
            .forEach { provider ->
                assertTrue("${provider.name} chat endpoint must be HTTPS", provider.endpoint.startsWith("https://"))
                assertTrue("${provider.name} models endpoint must be HTTPS", provider.modelsEndpoint.startsWith("https://"))
            }
    }
}
