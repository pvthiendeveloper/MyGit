import Foundation

/// A GGUF model MyGit can download and run on this Mac (llama.cpp's
/// `llama-server`), for commit messages, completions and the UI Inspector's
/// branch pick without sending code anywhere.
struct LocalModelSpec: Identifiable, Hashable, Sendable {
    /// Also the model id sent to the server and stored as the provider's model.
    let id: String
    let name: String
    /// "1.5B", "30B-A3B (MoE)".
    let parameters: String
    let quantization: String
    let sizeBytes: Int64
    /// Unified memory it wants to run comfortably (weights + context).
    let recommendedRAMGB: Int
    let url: URL
    /// SHA-256 of the file (Hugging Face's LFS etag), checked after download.
    let sha256: String
    let contextLength: Int
    let summary: String
    /// Suggested first pick for most Macs.
    var recommended = false

    var fileName: String { url.lastPathComponent }
}

enum LocalModelCatalog {
    /// Coding-oriented instruct models, smallest first. Sizes/hashes from
    /// huggingface.co (checked 2026-09).
    static let models: [LocalModelSpec] = [
        LocalModelSpec(
            id: "qwen2.5-coder-1.5b-instruct-q4_k_m", name: "Qwen2.5 Coder 1.5B Instruct",
            parameters: "1.5B", quantization: "Q4_K_M", sizeBytes: 986_048_800, recommendedRAMGB: 4,
            url: URL(string: "https://huggingface.co/bartowski/Qwen2.5-Coder-1.5B-Instruct-GGUF/resolve/main/Qwen2.5-Coder-1.5B-Instruct-Q4_K_M.gguf")!,
            sha256: "f530705d447660a4336c329981af164b471b60b974b1d808d57e8ec9fe23b239",
            contextLength: 8192,
            summary: "Tiny and fast. Fine for commit messages; weak at reasoning about code paths."),
        LocalModelSpec(
            id: "qwen3-4b-instruct-2507-q4_k_m", name: "Qwen3 4B Instruct 2507",
            parameters: "4B", quantization: "Q4_K_M", sizeBytes: 2_497_281_120, recommendedRAMGB: 8,
            url: URL(string: "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf")!,
            sha256: "3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597",
            contextLength: 16384,
            summary: "Best small all-rounder. Good default on 8–16 GB Macs.",
            recommended: true),
        LocalModelSpec(
            id: "gemma-3-4b-it-q4_k_m", name: "Gemma 3 4B IT",
            parameters: "4B", quantization: "Q4_K_M", sizeBytes: 2_489_757_856, recommendedRAMGB: 8,
            url: URL(string: "https://huggingface.co/ggml-org/gemma-3-4b-it-GGUF/resolve/main/gemma-3-4b-it-Q4_K_M.gguf")!,
            sha256: "882e8d2db44dc554fb0ea5077cb7e4bc49e7342a1f0da57901c0802ea21a0863",
            contextLength: 16384,
            summary: "Google's small model; solid writing, decent at code."),
        LocalModelSpec(
            id: "qwen2.5-coder-7b-instruct-q4_k_m", name: "Qwen2.5 Coder 7B Instruct",
            parameters: "7B", quantization: "Q4_K_M", sizeBytes: 4_683_074_336, recommendedRAMGB: 12,
            url: URL(string: "https://huggingface.co/bartowski/Qwen2.5-Coder-7B-Instruct-GGUF/resolve/main/Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf")!,
            sha256: "1664fccab734674a50763490a8c6931b70e3f2f8ec10031b54806d30e5f956b6",
            contextLength: 16384,
            summary: "Strong code model for its size. Good balance on 16 GB+."),
        LocalModelSpec(
            id: "qwen2.5-coder-14b-instruct-q4_k_m", name: "Qwen2.5 Coder 14B Instruct",
            parameters: "14B", quantization: "Q4_K_M", sizeBytes: 8_988_111_072, recommendedRAMGB: 18,
            url: URL(string: "https://huggingface.co/bartowski/Qwen2.5-Coder-14B-Instruct-GGUF/resolve/main/Qwen2.5-Coder-14B-Instruct-Q4_K_M.gguf")!,
            sha256: "2946d28c9e1bb2bcae6d42e8678863a31775df6f740315c7d7e6d6b6411f5937",
            contextLength: 16384,
            summary: "Noticeably better reasoning over code; slower. 24 GB+ recommended."),
        LocalModelSpec(
            id: "gpt-oss-20b-q4_k_m", name: "gpt-oss 20B",
            parameters: "21B-A3.6B (MoE)", quantization: "Q4_K_M", sizeBytes: 11_624_759_488, recommendedRAMGB: 16,
            url: URL(string: "https://huggingface.co/unsloth/gpt-oss-20b-GGUF/resolve/main/gpt-oss-20b-Q4_K_M.gguf")!,
            sha256: "c27536640e410032865dc68781d80a08b98f8db5e93575919af8ccc0568aeb4f",
            contextLength: 16384,
            summary: "OpenAI's open-weight reasoning model. Fast for its size (MoE)."),
        LocalModelSpec(
            id: "qwen3-coder-30b-a3b-instruct-q4_k_m", name: "Qwen3 Coder 30B-A3B Instruct",
            parameters: "30B-A3B (MoE)", quantization: "Q4_K_M", sizeBytes: 18_556_689_568, recommendedRAMGB: 32,
            url: URL(string: "https://huggingface.co/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF/resolve/main/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf")!,
            sha256: "fadc3e5f8d42bf7e894a785b05082e47daee4df26680389817e2093056f088ad",
            contextLength: 32768,
            summary: "Best local coder here; fast (3B active). Needs 32 GB+."),
    ]

    static func model(id: String) -> LocalModelSpec? { models.first { $0.id == id } }

    /// The llama.cpp release `llama-server` comes from (downloaded on first use).
    static let runtimeBuild = "b11177"
    static let runtimeURL = URL(string: "https://github.com/ggml-org/llama.cpp/releases/download/b11177/llama-b11177-bin-macos-arm64.tar.gz")!
    static let runtimeSHA256 = "815f8f3ddc8f57ceb792fed561bd6a6c6bd590578f3ad38604e7f70c49de1ac1"
    static let runtimeSizeBytes: Int64 = 11_202_247
}
