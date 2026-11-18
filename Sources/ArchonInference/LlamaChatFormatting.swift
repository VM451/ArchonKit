import Foundation
import ArchonAgent
import ArchonCore

/// Chat formatting, tool-schema injection, and GBNF JSON grammar definitions for `ArchonInference`.
enum LlamaChatFormatting {
    /// Upstream `grammars/json.gbnf` from `ggml-org/llama.cpp`.
    static let jsonObjectGBNF = #"""
    root   ::= object
    value  ::= object | array | string | number | ("true" | "false" | "null") ws

    object ::=
      "{" ws (
                string ":" ws value
        ("," ws string ":" ws value)*
      )? "}" ws

    array  ::=
      "[" ws (
                value
        ("," ws value)*
      )? "]" ws

    string ::=
      "\"" (
        [^"\\\x7F\x00-\x1F] |
        "\\" (["\\bfnrt] | "u" [0-9a-fA-F]{4})
      )* "\"" ws

    number ::= ("-"? ([0-9] | [1-9] [0-9]{0,15})) ("." [0-9]+)? ([eE] [-+]? [0-9] [1-9]{0,15})? ws

    ws ::= | " " | "\n" [ \t]{0,20}
    """#

    struct NormalizedMessage: Sendable, Equatable {
        let role: String
        let content: String
    }

    /// Normalizes `ChatMessage` roles and attaches tool specifications when provided.
    static func normalizedMessages(
        from prompt: [ChatMessage],
        tools: [ToolDefinition]
    ) -> [NormalizedMessage] {
        var messages: [NormalizedMessage] = []
        if !tools.isEmpty {
            messages.append(NormalizedMessage(
                role: "system",
                content: toolSystemInstructions(for: tools)
            ))
        }
        for message in prompt {
            let role: String
            switch message.role {
            case .system, .developer:
                role = "system"
            case .user:
                role = "user"
            case .assistant:
                role = "assistant"
            case .tool:
                role = "tool"
            }
            messages.append(NormalizedMessage(role: role, content: message.content))
        }
        return messages
    }

    /// Fallback ChatML formatter when no model-specific chat template applies.
    static func formatChatML(_ messages: [NormalizedMessage]) -> String {
        var output = ""
        for message in messages {
            output += "<|im_start|>\(message.role)\n\(message.content)<|im_end|>\n"
        }
        output += "<|im_start|>assistant\n"
        return output
    }

    static func toolSystemInstructions(for tools: [ToolDefinition]) -> String {
        let schemas = tools.map { tool -> [String: Any] in
            [
                "name": tool.name,
                "description": tool.description,
                "parameters": tool.parametersJSONSchema.mapValues(\.value)
            ]
        }
        let encoded: String
        if let data = try? JSONSerialization.data(withJSONObject: schemas, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            encoded = json
        } else {
            encoded = "[]"
        }
        return """
        You have access to the following tools:
        \(encoded)
        When calling a tool, respond with <tool_call>{"name":"<tool_name>","arguments":{...}}</tool_call>.
        """
    }

    /// Extracts `<tool_call>{...}</tool_call>` blocks or direct JSON tool envelopes when present.
    static func extractToolCalls(
        from text: String,
        allowedTools: [ToolDefinition]
    ) -> (cleanedText: String, toolCalls: [ToolCall]) {
        guard !allowedTools.isEmpty else {
            return (text, [])
        }
        let allowedNames = Set(allowedTools.map(\.name))
        var parsedCalls: [ToolCall] = []
        var cleaned = text

        let openTag = "<tool_call>"
        let closeTag = "</tool_call>"
        while let openRange = cleaned.range(of: openTag),
              let closeRange = cleaned.range(of: closeTag, range: openRange.upperBound..<cleaned.endIndex) {
            let payload = String(cleaned[openRange.upperBound..<closeRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let calls = decodeToolPayload(payload, allowedNames: allowedNames) {
                parsedCalls.append(contentsOf: calls)
            }
            cleaned.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
        }

        if parsedCalls.isEmpty {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{"),
               let calls = decodeToolPayload(trimmed, allowedNames: allowedNames) {
                parsedCalls.append(contentsOf: calls)
                cleaned = ""
            }
        }

        return (cleaned.trimmingCharacters(in: .whitespacesAndNewlines), parsedCalls)
    }

    private static func decodeToolPayload(_ json: String, allowedNames: Set<String>) -> [ToolCall]? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let batch = object["tool_calls"] as? [[String: Any]] {
            let calls = batch.compactMap { decodeSingleToolObject($0, allowedNames: allowedNames) }
            return calls.isEmpty ? nil : calls
        }
        if let single = decodeSingleToolObject(object, allowedNames: allowedNames) {
            return [single]
        }
        return nil
    }

    private static func decodeSingleToolObject(_ object: [String: Any], allowedNames: Set<String>) -> ToolCall? {
        guard let name = object["name"] as? String, allowedNames.contains(name) else {
            return nil
        }
        let argumentsString: String
        if let argsString = object["arguments"] as? String {
            argumentsString = argsString
        } else if let argsDict = object["arguments"],
                  JSONSerialization.isValidJSONObject(argsDict),
                  let data = try? JSONSerialization.data(withJSONObject: argsDict, options: [.sortedKeys]),
                  let encoded = String(data: data, encoding: .utf8) {
            argumentsString = encoded
        } else {
            argumentsString = "{}"
        }
        let callID = (object["id"] as? String) ?? UUID().uuidString
        return ToolCall(id: callID, name: name, arguments: argumentsString)
    }
}
