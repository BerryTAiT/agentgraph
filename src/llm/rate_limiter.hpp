#pragma once

#include <chrono>
#include <condition_variable>
#include <mutex>

namespace agentgraph {

// Thread-safe token bucket. `rate` is the sustained number of permits per
// minute (0 disables limiting). The bucket refills continuously at `rate/60`
// permits per second and bursts up to `rate` permits, which lets a burst of
// concurrent requests go out immediately while still capping the sustained
// requests-per-minute to `rate`. acquire() blocks (sleeping on a condition
// variable, not spinning) until a permit is available, so callers that hit a
// provider's token-per-minute limit are throttled instead of 429-ing.
class RateLimiter {
public:
    explicit RateLimiter(int rate_per_minute = 0)
        : rate_per_minute_(rate_per_minute < 0 ? 0 : rate_per_minute),
          tokens_(rate_per_minute),
          last_refill_(std::chrono::steady_clock::now()) {}

    void set_rate(int rate_per_minute) {
        std::lock_guard<std::mutex> lk(mu_);
        rate_per_minute_ = rate_per_minute < 0 ? 0 : rate_per_minute;
        tokens_ = rate_per_minute_;
        last_refill_ = std::chrono::steady_clock::now();
    }

    int rate() const { return rate_per_minute_; }

    void acquire() {
        if (rate_per_minute_ <= 0) return;

        std::unique_lock<std::mutex> lk(mu_);
        while (true) {
            refill();
            if (tokens_ > 0) {
                tokens_ -= 1;
                return;
            }
            // No permit yet: sleep until the next refill tick.
            cv_.wait_for(lk, std::chrono::milliseconds(refill_interval_ms()));
        }
    }

private:
    using Clock = std::chrono::steady_clock;

    long refill_interval_ms() const {
        // One permit every 60/rate seconds, but never longer than 1s so the
        // wait remains responsive.
        long ms = (rate_per_minute_ > 0) ? (60000L / rate_per_minute_) : 1000L;
        return ms < 1 ? 1 : ms;
    }

    void refill() {
        auto now = Clock::now();
        double elapsed_sec =
            std::chrono::duration<double>(now - last_refill_).count();
        double new_tokens = elapsed_sec * (rate_per_minute_ / 60.0);
        if (new_tokens >= 1.0) {
            tokens_ += static_cast<long>(new_tokens);
            if (tokens_ > rate_per_minute_) tokens_ = rate_per_minute_;
            last_refill_ = now;
        }
    }

    int rate_per_minute_;
    long tokens_;
    Clock::time_point last_refill_;
    std::mutex mu_;
    std::condition_variable cv_;
};

} // namespace agentgraph
