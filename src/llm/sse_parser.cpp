#include "sse_parser.hpp"

namespace agentgraph {

void SSEParser::feed(const std::string& chunk, const SSECallback& callback) {
    buffer_ += chunk;

    size_t pos;
    // Events are separated by a blank line: "\n\n" or "\r\n\r\n".
    while ((pos = buffer_.find("\n\n")) != std::string::npos ||
           (pos = buffer_.find("\r\n\r\n")) != std::string::npos) {
        bool crlf = (buffer_.compare(pos, 4, "\r\n\r\n") == 0);
        std::string event = buffer_.substr(0, pos);
        buffer_.erase(0, pos + (crlf ? 4 : 2));

        std::string data_line;
        size_t start = 0;
        while (start < event.size()) {
            size_t line_end = event.find('\n', start);
            if (line_end == std::string::npos) line_end = event.size();

            std::string line = event.substr(start, line_end - start);
            start = line_end + 1;

            // strip trailing '\r' (from CRLF)
            if (!line.empty() && line.back() == '\r') line.pop_back();

            if (line.rfind("data:", 0) == 0) {
                std::string data = line.substr(5);
                while (!data.empty() && data.front() == ' ') data.erase(0, 1);

                if (data == "[DONE]") {
                    return;
                }
                data_line = data;
            }
        }

        if (!data_line.empty()) {
            try {
                auto parsed = json::parse(data_line);
                callback(parsed);
            } catch (...) {
                // skip malformed JSON chunks
            }
        }
    }
}

void SSEParser::flush(const SSECallback& callback) {
    if (!buffer_.empty()) {
        feed("\n\n", callback);
        buffer_.clear();
    }
}

} // namespace agentgraph
