import Foundation

/// How a probe checks connectivity.
public enum ProbeMode: String, CaseIterable, Sendable {
    case ping
    case http

    public var name: String {
        switch self {
        case .ping: return "Ping"
        case .http: return "Fetch URL"
        }
    }
}

/// Which HTTP responses count as success.
public enum HTTPExpectation: String, CaseIterable, Sendable {
    /// Only 204 No Content, like Android's connectivity check. Anything else is
    /// treated as interference, typically a captive portal.
    case noContent = "204"
    /// Any 2xx response.
    case anySuccess = "2xx"

    public var name: String {
        switch self {
        case .noContent: return "204 No Content only"
        case .anySuccess: return "Any 2xx"
        }
    }

    /// Classify an HTTP status code (redirects are not followed). Returns `nil` on success.
    public func failure(forStatus status: Int) -> FailureReason? {
        let isRedirect = (300..<400).contains(status)
        switch self {
        case .noContent:
            if status == 204 { return nil }
            // A login page (200) or a redirect where we expected an empty 204.
            if status == 200 || isRedirect { return .captivePortal }
            return .unexpectedStatus(status)
        case .anySuccess:
            if (200..<300).contains(status) { return nil }
            if isRedirect { return .captivePortal }
            return .unexpectedStatus(status)
        }
    }
}

/// Builds and parses ICMP echo (ping) packets for IPv4.
public enum ICMPEcho {
    public static let echoRequestType: UInt8 = 8
    public static let echoReplyType: UInt8 = 0

    /// An ICMP echo request with a valid checksum.
    public static func request(identifier: UInt16, sequence: UInt16, payload: [UInt8]) -> [UInt8] {
        var packet: [UInt8] = [
            echoRequestType, 0, // type, code
            0, 0, // checksum, filled in below
            UInt8(identifier >> 8), UInt8(identifier & 0xff),
            UInt8(sequence >> 8), UInt8(sequence & 0xff),
        ]
        packet.append(contentsOf: payload)
        let sum = checksum(packet)
        packet[2] = UInt8(sum >> 8)
        packet[3] = UInt8(sum & 0xff)
        return packet
    }

    /// Internet checksum (RFC 1071) over `bytes`.
    public static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < bytes.count {
            sum += (UInt32(bytes[index]) << 8) | UInt32(bytes[index + 1])
            index += 2
        }
        if index < bytes.count {
            sum += UInt32(bytes[index]) << 8
        }
        while sum >> 16 != 0 {
            sum = (sum & 0xffff) + (sum >> 16)
        }
        return ~UInt16(sum)
    }

    public struct Reply: Equatable, Sendable {
        public var identifier: UInt16
        public var sequence: UInt16
    }

    /// Parses an echo reply. Accepts packets with or without a leading IPv4 header
    /// (macOS datagram ICMP sockets include it). Returns `nil` for anything else.
    public static func parseReply(_ bytes: [UInt8]) -> Reply? {
        var offset = 0
        if let first = bytes.first, first >> 4 == 4 {
            let headerLength = Int(first & 0x0f) * 4
            guard headerLength >= 20, bytes.count >= headerLength else { return nil }
            offset = headerLength
        }
        guard bytes.count - offset >= 8,
              bytes[offset] == echoReplyType,
              bytes[offset + 1] == 0
        else { return nil }
        let identifier = (UInt16(bytes[offset + 4]) << 8) | UInt16(bytes[offset + 5])
        let sequence = (UInt16(bytes[offset + 6]) << 8) | UInt16(bytes[offset + 7])
        return Reply(identifier: identifier, sequence: sequence)
    }
}
