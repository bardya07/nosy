// Nosy's one shot, offline summary helper. The process owns and releases all model memory.
#include "llama.h"
#include <algorithm>
#include <clocale>
#include <cstdio>
#include <fstream>
#include <iterator>
#include <string>
#include <thread>
#include <vector>

int main(int argc, char **argv) {
    std::setlocale(LC_NUMERIC, "C");
    std::string model_path, prompt_path;
    int predict = 600, context = 8192;
    for (int i = 1; i < argc; ++i) {
        if (i + 1 >= argc) return 2;
        std::string arg = argv[i], value = argv[++i];
        try {
            if (arg == "--model") model_path = value;
            else if (arg == "--prompt-file") prompt_path = value;
            else if (arg == "--predict") predict = std::stoi(value);
            else if (arg == "--ctx") context = std::stoi(value);
            else return 2;
        } catch (...) { return 2; }
    }
    if (model_path.empty() || prompt_path.empty() || predict < 1 || predict > 1200 || context != 8192) return 2;
    std::ifstream input(prompt_path);
    if (!input) return 2;
    const std::string text((std::istreambuf_iterator<char>(input)), std::istreambuf_iterator<char>());
    if (text.size() > 100000) return 2;
    // Both pinned models use ChatML. Empty thinking explicitly selects SmolLM3's non reasoning mode.
    const std::string prompt = "<|im_start|>system\nYou summarize transcripts faithfully. /no_think<|im_end|>\n<|im_start|>user\n" +
        text + "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n";
    llama_backend_init();
    auto mp = llama_model_default_params();
    mp.n_gpu_layers = 99;
    llama_model *model = llama_model_load_from_file(model_path.c_str(), mp);
    if (!model) { fprintf(stderr, "Could not load the summary model.\n"); return 1; }
    const llama_vocab *vocab = llama_model_get_vocab(model);
    int count = -llama_tokenize(vocab, prompt.c_str(), (int)prompt.size(), nullptr, 0, true, true);
    if (count <= 0 || count + predict > context) {
        fprintf(stderr, "Summary input exceeds the context budget.\n");
        llama_model_free(model); llama_backend_free(); return 3;
    }
    std::vector<llama_token> tokens(count);
    if (llama_tokenize(vocab, prompt.c_str(), (int)prompt.size(), tokens.data(), count, true, true) != count) {
        fprintf(stderr, "Could not tokenize the summary input.\n");
        llama_model_free(model); llama_backend_free(); return 1;
    }
    auto cp = llama_context_default_params();
    cp.n_ctx = context; cp.n_batch = 512; cp.n_ubatch = 256;
    cp.n_threads = cp.n_threads_batch = std::min(4u, std::max(1u, std::thread::hardware_concurrency()));
    llama_context *ctx = llama_init_from_model(model, cp);
    if (!ctx) { llama_model_free(model); llama_backend_free(); return 1; }
    auto *batch = llama_batch_ext_init(ctx);
    int pos = 0, status = 0;
    while (pos < count) {
        llama_batch_ext_clear(batch);
        int n = std::min(512, count - pos);
        for (int i = 0; i < n; ++i) {
            int idx = llama_batch_ext_add_token(batch, 0, tokens[pos]);
            if (idx < 0 || !llama_batch_ext_set_pos(batch, idx, &pos)) { status = 1; break; }
            ++pos;
        }
        if (status != 0) break;
        llama_batch_ext_set_output_logits(batch, n - 1, true);
        if (llama_process(ctx, LLAMA_PROCESS_TYPE_DECODE, batch)) { status = 1; break; }
    }
    llama_sampler *sampler = llama_sampler_init_greedy();
    bool finished = false;
    for (int i = 0; status == 0 && i < predict; ++i) {
        llama_token token = llama_sampler_sample(sampler, ctx, -1);
        if (llama_vocab_is_eog(vocab, token)) { finished = true; break; }
        char piece[512];
        int n = llama_token_to_piece(vocab, token, piece, sizeof(piece), 0, false);
        if (n < 0) { status = 1; break; }
        fwrite(piece, 1, n, stdout);
        llama_batch_ext_clear(batch);
        int idx = llama_batch_ext_add_token(batch, 0, token);
        llama_batch_ext_set_pos(batch, idx, &pos); ++pos;
        llama_batch_ext_set_output_logits(batch, idx, true);
        if (llama_process(ctx, LLAMA_PROCESS_TYPE_DECODE, batch)) status = 1;
    }
    if (status == 0) {
        if (finished) fprintf(stderr, "NOSY_LLAMA_COMPLETE\n");
        else {
            fprintf(stderr, "Summary output reached the token limit before finishing.\n");
            status = 4;
        }
    }
    fflush(stdout);
    llama_sampler_free(sampler); llama_batch_ext_free(batch);
    llama_free(ctx); llama_model_free(model); llama_backend_free();
    return status;
}
