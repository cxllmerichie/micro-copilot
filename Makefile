VERSION ?= 2.0.15


.PHONY: bootstrap
bootstrap: clone patch build

.PHONY: clone
clone:
	@echo "Cloning official \"micro\" and checking out release v$(VERSION)..."
	@if [ ! -d "micro" ]; then \
		git clone https://github.com/zyedidia/micro && \
		cd micro && \
		git checkout 6a62575bcfdf4965f187eedafceb3400316e612b; \
	else \
		echo "\"micro\" dir already exists."; \
	fi

.PHONY: patch
patch:
	@echo "Applying virtual text engine patch..."
	@cd micro && git apply ../patches/$(VERSION).patch || echo "Patch already applied or failed."

.PHONY: build
build:
	@cd micro && make build
	@sudo cp micro/micro /usr/bin/micro
	@echo "\"micro\" binary is located at /usr/bin/micro"

.PHONY: install
path ?= ~/.config/micro/plug/copilot
file ?= plugin.lua
install:
	@mkdir -p $(path)
	@cp plugin/plugin.lua $(path)/$(file)
	@echo "Plugin installed successfully!"

.PHONY: dev
dev: clone
	@echo "Setting up development environment..."
	@cd micro && git checkout -b copilot-dev
	@cd micro && git apply ../patches/$(VERSION).patch
	@cd micro && git add . && git commit -m "Apply Copilot virtual text patch"
	@echo "Ready for development on branch 'copilot-dev' inside micro/"

.PHONY: patchgen
patchgen:
	@echo "Generating new patch from copilot-dev branch..."
	@cd micro && git format-patch HEAD~1 --stdout > ../patches/$(VERSION).patch
	@echo "Saved updated patch to patches/$(VERSION).patch"

.PHONY: help
help:
	@echo "Micro Copilot"
	@echo "=========================="
	@echo "Available commands:"
	@echo "  make clone         - Clone micro and checkout v$(VERSION)"
	@echo "  make patch   		- Apply the virtual text patch to the micro source"
	@echo "  make build         - Build the micro binary"
	@echo "  make install       - Install the Lua plugin to your local config"
	@echo "  make bootstrap     - Run clone, patch, and build in sequence"
	@echo "  make dev           - Clone, branch, and apply patch for development"
	@echo "  make patchgen      - Regenerate patches/$(VERSION).patch from your commits"


backend ?= cuda
# backend ?= vulkan

gpu ?= nvidia
# gpu ?= intel

ifeq ($(backend), cuda)
	DOCKER_HW_OPTS := --gpus all
	flash_attn ?= auto
else ifeq ($(gpu), nvidia)
	DOCKER_HW_OPTS := --gpus all
	flash_attn ?= off
else
	DOCKER_HW_OPTS := --device /dev/dri:/dev/dri
	flash_attn ?= off
endif


.PHONY: copilot
copilot: name ?= copilot
copilot: models_dir ?= /data/models/
copilot: model ?= copilot/qwen2.5-coder-1.5b-q8_0.gguf
#copilot: model ?= copilot/deepseek-coder-1.3b-base.Q8_0.gguf
copilot: port := 65432
# The total context window size (in tokens) to allocate for the model.
# - Lower = uses less VRAM, but limits the amount of code it can read at once.
# - Higher = allows it to read more surrounding code, but eats VRAM quickly.
# - Optimal: 2048 (balanced for FIM tasks).
copilot: ctx_size := 2048
# Inter-Process Communication (IPC) namespace mode for the container.
# - private = isolated IPC with default 64 MiB /dev/shm (causes bus errors/crashes with GPU drivers).
# - host = shares host IPC namespace and full /dev/shm (enables zero-copy DMA and fast shared memory).
# - Optimal: host (prevents out-of-shared-memory errors).
ipc ?= host
# Maximum memory (in bytes, or -1 for unlimited) allowed to be locked into physical RAM.
# - default (64 KiB) = causes mlock and GPU pinned memory allocations to fail with ENOMEM.
# - -1 = allows pinning model weights in RAM and direct DMA transfers without disk swapping.
# - Optimal: -1 (unlimited).
ulimit_memlock ?= -1
# Maximum process call stack size in bytes.
# - default (8388608 / 8 MiB) = risks stack overflow (SIGSEGV) during deep graph evaluation or large contexts.
# - higher (67108864 / 64 MiB) = provides ample headroom for deep recursive parsing and worker threads.
# - Optimal: 67108864 (64 MiB).
ulimit_stack ?= 67108864
# The number of CPU threads to use.
# - Lower = saves CPU power.
# - Higher = faster CPU ops (until it exceeds physical cores and thrashes cache).
# - Optimal: Physical core count (e.g. 6).
copilot: threads ?= 6
# The number of tokens processed in a single batch.
# - Lower = uses less VRAM.
# - Higher = better overall throughput but increases time-to-first-token.
# - Optimal: 512 (for balanced latency and throughput).
copilot: batch_size ?= 512
# The micro-batch size used to split large batches for processing.
# - Lower = saves memory footprint.
# - Higher = faster processing if VRAM allows it.
# - Optimal: Matches batch_size (e.g. 512).
copilot: ubatch_size ?= 256
# The memory margin (in MiB) to leave free on the GPU when fitting layers automatically.
# - Lower = fits more layers into VRAM.
# - Higher = safer from Out-Of-Memory crashes.
# - Optimal: 256 (safe margin).
copilot: fit_target ?= 256
# The minimum context size to reserve memory for when fitting layers automatically.
# - Lower = allows fitting more layers on low VRAM GPUs.
# - Higher = prevents OOMs on massive prompts.
# - Optimal: Matches max(n_prompt + n_gen) (e.g. 2048).
copilot: fit_ctx ?= 2048
# How the model file is loaded into memory.
# - mmap = fast startup, lazy OS loading.
# - mlock = forces model to stay pinned in RAM (avoids page faults).
# - Optimal: mmap (saves system RAM).
copilot: load_mode ?= mmap
# Whether to lazy-load specific tensors (like embeddings) on demand.
# - auto = saves memory for large tensors.
# - off = forces everything into memory immediately.
# - Optimal: auto (smart memory management).
copilot: lazy_mode ?= auto
# The percentage of CPU polling (busy-waiting) to use when syncing with the GPU.
# - 100 = lowest latency/highest speed but 100% CPU usage.
# - 0 = CPU sleeps (saves power, adds micro-delays).
# - Optimal: 50 (balanced responsiveness and power draw).
copilot: poll ?= 50
# The number of concurrent requests the server can process.
# - Lower = dedicates all resources to a single completion, fastest latency.
# - Higher = splits context across multiple requests (for multiple users).
# - Optimal: 1 (perfect for single-user editor autocomplete).
copilot: parallel ?= 1
copilot: is_verbose := true
copilot: args :=
# https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md
# https://github.com/ggml-org/llama.cpp/blob/master/docs/docker.md
copilot:
	@docker run --rm -it \
		--name $(name) \
		$(DOCKER_HW_OPTS) \
		--ipc=$(ipc) \
		--ulimit memlock=$(ulimit_memlock) \
		--ulimit stack=$(ulimit_stack) \
		--publish $(port):$(port) \
		--volume $(models_dir):/models:ro \
		--entrypoint /app/llama-server \
		ghcr.io/ggml-org/llama.cpp:server-$(backend) \
		--model /models/$(model) \
		--no-webui \
		--host 0.0.0.0 \
		--port $(port) \
		--threads $(threads) \
		--batch-size $(batch_size) \
		--ubatch-size $(ubatch_size) \
		--ctx-size $(ctx_size) \
		--fit on \
		--fit-target $(fit_target) \
		--fit-ctx $(fit_ctx) \
		--flash-attn $(flash_attn) \
		--load-mode $(load_mode) \
		--lazy-mode $(lazy_mode) \
		--poll $(poll) \
		--parallel $(parallel) \
		--alias $(name),$(model) \
		$(if $(filter true,$(is_verbose)),--verbose) \
		$(args)
