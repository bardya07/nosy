// Batch protocol: model, requests.json, results.json. One model load; <=30 s per request.
#import <Foundation/Foundation.h>
#include <whisper.h>
#include <ggml-backend.h>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <fstream>
#include <map>
#include <set>
#include <vector>
#include <sys/resource.h>

struct Node { std::map<int,int> edges; bool terminal = false; };
struct Bias { std::vector<Node> trie{1}; int calls = 0; int changed = 0; };
static std::vector<whisper_token> tokenize(whisper_context *ctx, const std::string &text) {
    int n = -whisper_tokenize(ctx, text.c_str(), nullptr, 0);
    if (n <= 0) return {};
    std::vector<whisper_token> tokens(n);
    n = whisper_tokenize(ctx, text.c_str(), tokens.data(), int(tokens.size()));
    if (n < 0) return {};
    tokens.resize(n); return tokens;
}
static void add(Bias &b, const std::vector<whisper_token> &tokens) {
    int node = 0;
    for (int token : tokens) {
        auto it = b.trie[node].edges.find(token);
        if (it == b.trie[node].edges.end()) {
            int next = int(b.trie.size()); b.trie[node].edges[token] = next;
            b.trie.emplace_back(); node = next;
        } else node = it->second;
    }
    b.trie[node].terminal = true;
}
static void filter(whisper_context *ctx, whisper_state *, const whisper_token_data *tokens, int n, float *logits, void *user) {
    auto &b = *static_cast<Bias *>(user); ++b.calls;
    int eot = whisper_token_eot(ctx), count = whisper_n_vocab(ctx);
    int best = int(std::max_element(logits, logits + count) - logits);
    if (best >= eot) return; // Protect every special-token winner, including EOT.
    float top = logits[best];
    std::set<int> completed;
    // Replay each hypothesis independently: callback state is never shared between beams.
    for (int start = 0; start < n; ++start) {
        int node = 0;
        for (int i = start; i < n; ++i) {
            auto it = b.trie[node].edges.find(tokens[i].id);
            if (it == b.trie[node].edges.end()) break;
            node = it->second;
            if (b.trie[node].terminal) completed.insert(node);
        }
    }
    std::map<int,float> bonuses;
    auto propose = [&](int node, int depth) {
        for (auto [token,next] : b.trie[node].edges) {
            if (token >= eot || completed.count(next) || !std::isfinite(logits[token])) continue;
            float gap = top - logits[token];
            if (gap > (depth ? 3.0f : 2.0f)) continue;
            if (!depth) {
                int rank = 0;
                for (int i = 0; i < eot; ++i) if (logits[i] > logits[token] && ++rank >= 20) break;
                if (rank >= 20) continue;
            }
            // Total nominal phrase bonus <=1.2; shared paths take a maximum.
            float bonus = depth ? std::min(0.4f, 1.2f / float(depth + 1)) : 0.1f;
            bonuses[token] = std::max(bonuses[token], bonus);
        }
    };
    // Leading-space variants enforce lexical entry after the start of a hypothesis.
    if (n == 0 || (n > 0 && tokens[n-1].id < eot)) propose(0,0);
    for (int start = std::max(0,n-20); start < n; ++start) {
        int node = 0; bool matched = true;
        for (int i = start; i < n; ++i) {
            auto it = b.trie[node].edges.find(tokens[i].id);
            if (it == b.trie[node].edges.end()) { matched = false; break; }
            node = it->second;
        }
        if (matched && !b.trie[node].terminal) propose(node,n-start);
    }
    for (auto [token,bonus] : bonuses) { logits[token] += bonus; ++b.changed; }
}
struct Deadline { std::chrono::steady_clock::time_point end; };
static bool abortDecode(void *user) { return std::chrono::steady_clock::now() > static_cast<Deadline *>(user)->end; }
static void silent(enum ggml_log_level, const char *, void *) {}
int main(int argc, char **argv) { @autoreleasepool {
    if (argc != 4) return 64;
    setpriority(PRIO_PROCESS, 0, 10);
    ggml_backend_load_all_from_path("/opt/homebrew/opt/ggml/libexec");
    ggml_backend_load_all_from_path("/usr/local/opt/ggml/libexec");
    whisper_log_set(silent,nullptr);
    auto cp = whisper_context_default_params();
    auto *ctx = whisper_init_from_file_with_params(argv[1],cp);
    if (!ctx) return 65;
    NSData *data = [NSData dataWithContentsOfFile:@(argv[2])];
    NSArray *requests = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![requests isKindOfClass:[NSArray class]]) { whisper_free(ctx); return 66; }
    NSMutableArray *results = [NSMutableArray array];
    for (NSDictionary *req in requests) { @autoreleasepool {
        NSData *pcm = [NSData dataWithContentsOfFile:req[@"audio"] options:NSDataReadingMappedIfSafe error:nil];
        NSUInteger count = pcm.length / sizeof(float);
        if (count == 0 || count > 480000) continue;
        auto prompt = tokenize(ctx, [req[@"prompt"] ?: @"" UTF8String]);
        if (prompt.size() > 160) continue; // Refuse silent native truncation.
        Bias bias;
        if ([req[@"bias"] boolValue]) {
            for (NSString *term in req[@"candidates"]) {
                add(bias,tokenize(ctx,std::string(" ") + term.UTF8String));
                add(bias,tokenize(ctx,term.UTF8String));
            }
        }
        auto p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
        p.n_threads = 4; p.language = "en"; p.no_context = true;
        p.single_segment = true; p.no_timestamps = true; p.vad = false;
        p.print_realtime = false; p.print_progress = false; p.print_timestamps = false;
        p.prompt_tokens = prompt.empty() ? nullptr : prompt.data(); p.prompt_n_tokens = int(prompt.size());
        p.carry_initial_prompt = true; p.n_max_text_ctx = prompt.empty() ? 0 : int(prompt.size()) + 1;
        p.temperature = 0; p.temperature_inc = 0; p.greedy.best_of = 1; p.max_tokens = 220;
        Deadline deadline{std::chrono::steady_clock::now() + std::chrono::seconds(60)};
        p.abort_callback = abortDecode; p.abort_callback_user_data = &deadline;
        if ([req[@"bias"] boolValue]) { p.logits_filter_callback = filter; p.logits_filter_callback_user_data = &bias; }
        auto begin = std::chrono::steady_clock::now();
        int status = whisper_full(ctx,p,static_cast<const float *>(pcm.bytes),int(count));
        NSMutableString *text = [NSMutableString string]; int tokens = 0;
        NSMutableArray *evidence = [NSMutableArray array];
        if (status == 0) for (int i=0; i<whisper_full_n_segments(ctx); ++i) {
            [text appendString:@(whisper_full_get_segment_text(ctx,i))]; tokens += whisper_full_n_tokens(ctx,i);
            for (int j=0; j<whisper_full_n_tokens(ctx,i); ++j) {
                auto token = whisper_full_get_token_data(ctx,i,j);
                [evidence addObject:@{@"text":@(whisper_full_get_token_text(ctx,i,j)), @"id":@(token.id), @"p":@(token.p)}];
            }
        }
        double elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now()-begin).count();
        [results addObject:@{@"id":req[@"id"], @"text":text, @"status":@(status), @"seconds":@(elapsed), @"tokens":@(tokens), @"promptTokens":@(prompt.size()), @"evidence":evidence, @"callbackCalls":@(bias.calls), @"biasedTokens":@(bias.changed)}];
        NSData *output = [NSJSONSerialization dataWithJSONObject:results options:NSJSONWritingPrettyPrinted error:nil];
        if (![output writeToFile:@(argv[3]) atomically:YES]) { whisper_free(ctx); return 67; }
    }}
    whisper_free(ctx); return 0;
}}
