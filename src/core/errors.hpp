#pragma once

#include <string>
#include <variant>
#include <stdexcept>

namespace agentgraph {

struct Error {
    std::string message;
    std::string code;

    Error() = default;
    Error(const std::string& msg, const std::string& c = "")
        : message(msg), code(c) {}
};

template<typename T>
class Result {
public:
    static Result ok(T value) {
        Result r;
        r.value_ = std::move(value);
        return r;
    }

    static Result err(const std::string& message, const std::string& code = "") {
        Result r;
        r.value_ = Error{message, code};
        return r;
    }

    bool is_ok() const { return std::holds_alternative<T>(value_); }
    bool is_err() const { return std::holds_alternative<Error>(value_); }

    const T& value() const {
        if (is_err()) throw std::runtime_error("Result::value() called on error: " + error().message);
        return std::get<T>(value_);
    }

    T& value() {
        if (is_err()) throw std::runtime_error("Result::value() called on error: " + error().message);
        return std::get<T>(value_);
    }

    const Error& error() const { return std::get<Error>(value_); }

    T value_or(T default_val) const {
        return is_ok() ? std::get<T>(value_) : std::move(default_val);
    }

private:
    std::variant<T, Error> value_;
};

template<>
class Result<void> {
public:
    static Result ok() {
        Result r;
        r.has_error_ = false;
        return r;
    }

    static Result err(const std::string& message, const std::string& code = "") {
        Result r;
        r.has_error_ = true;
        r.error_ = Error{message, code};
        return r;
    }

    bool is_ok() const { return !has_error_; }
    bool is_err() const { return has_error_; }
    const Error& error() const { return error_; }

private:
    bool has_error_ = false;
    Error error_;
};

} // namespace agentgraph
