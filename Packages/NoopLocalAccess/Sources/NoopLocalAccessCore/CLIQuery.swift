import Foundation

public struct NoopCLIQueryRequest: Equatable, Sendable {
    public let toolName: String
    public let arguments: [String: JSONValue]
    public let configuration: LocalAccessConfiguration

    public init(
        toolName: String,
        arguments: [String: JSONValue],
        configuration: LocalAccessConfiguration = .environment()
    ) {
        self.toolName = toolName
        self.arguments = arguments
        self.configuration = configuration
    }
}

public enum NoopCLIQueryError: Error, CustomStringConvertible, Equatable {
    case usage(String)

    public var description: String {
        switch self {
        case .usage(let message): return message
        }
    }

    public var exitCode: Int32 { 64 }
}

public enum NoopCLIQuery {
    public static func parse(arguments: [String]) throws -> NoopCLIQueryRequest {
        guard let toolName = arguments.first, !toolName.hasPrefix("-") else {
            throw NoopCLIQueryError.usage("query requires one tool name")
        }
        guard NoopToolDispatcher.toolNames.contains(toolName) else {
            throw NoopCLIQueryError.usage("unknown query tool")
        }

        var toolArguments: [String: JSONValue] = [:]
        var configuration = LocalAccessConfiguration.environment()
        var seenFlags = Set<String>()
        var index = 1

        while index < arguments.count {
            let flag = arguments[index]
            guard flag.hasPrefix("--") else {
                throw NoopCLIQueryError.usage("query does not accept additional positional arguments")
            }
            guard seenFlags.insert(flag).inserted else {
                throw NoopCLIQueryError.usage("duplicate query flag: \(flag)")
            }
            index += 1

            switch flag {
            case "--db-path":
                configuration.databasePath = try requiredValue(flag, arguments: arguments, index: &index)
            case "--days":
                guard toolName != "data_freshness" else { throw unsupported(flag, toolName: toolName) }
                toolArguments["days"] = try integerValue(flag, arguments: arguments, index: &index)
            case "--key":
                guard toolName == "metric_series" else { throw unsupported(flag, toolName: toolName) }
                toolArguments["key"] = .string(try requiredValue(flag, arguments: arguments, index: &index))
            case "--source":
                guard toolName == "metric_series" else { throw unsupported(flag, toolName: toolName) }
                toolArguments["source"] = .string(try requiredValue(flag, arguments: arguments, index: &index))
            case "--from-day":
                guard toolName == "metric_series" else { throw unsupported(flag, toolName: toolName) }
                toolArguments["from_day"] = .string(try requiredValue(flag, arguments: arguments, index: &index))
            case "--to-day":
                guard toolName == "metric_series" else { throw unsupported(flag, toolName: toolName) }
                toolArguments["to_day"] = .string(try requiredValue(flag, arguments: arguments, index: &index))
            case "--limit":
                guard toolName == "metric_series" else { throw unsupported(flag, toolName: toolName) }
                toolArguments["limit"] = try integerValue(flag, arguments: arguments, index: &index)
            default:
                throw NoopCLIQueryError.usage("unknown query flag")
            }
        }

        if toolName == "metric_series", toolArguments["key"] == nil {
            throw NoopCLIQueryError.usage("metric_series requires --key")
        }

        return NoopCLIQueryRequest(toolName: toolName, arguments: toolArguments, configuration: configuration)
    }

    public static func dispatch(_ request: NoopCLIQueryRequest) throws -> JSONValue {
        try NoopToolDispatcher(configuration: request.configuration)
            .dispatch(name: request.toolName, arguments: request.arguments)
    }

    public static func encodeLine(_ value: JSONValue) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        return data
    }

    private static func requiredValue(_ flag: String, arguments: [String], index: inout Int) throws -> String {
        guard index < arguments.count, !arguments[index].hasPrefix("--") else {
            throw NoopCLIQueryError.usage("missing value for \(flag)")
        }
        defer { index += 1 }
        return arguments[index]
    }

    private static func integerValue(_ flag: String, arguments: [String], index: inout Int) throws -> JSONValue {
        let raw = try requiredValue(flag, arguments: arguments, index: &index)
        guard let value = Int(raw) else {
            throw NoopCLIQueryError.usage("value for \(flag) must be an integer")
        }
        return .int(value)
    }

    private static func unsupported(_ flag: String, toolName: String) -> NoopCLIQueryError {
        .usage("\(flag) is not supported for \(toolName)")
    }
}
