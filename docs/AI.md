# Local AI on the BC-250

> [!NOTE]
> Copied from the linux-cachyos-bc250 repository (`bfb1d54b`), where the kernel patches, Mesa and PyTorch
> packages for the BC-250 board's GPU are made. The PS5 has the same GPU family (GFX1013), and this
> image ships those patches and that Mesa. **Its numbers are measured on a BC-250, not on a PS5 (except [Inkling-2-Mini](#faster-chat-inkling-2-mini) and [Qwen3.8-Flash-Next](#biggest-model-qwen38-flash-next-ps5-only), measured on a PS5 Pro): the PS5's clocks, CU count and memory differ, so take them as a starting point. Where the BC-250 needs something different from the PS5, this copy says what to do on the PS5.**

The setups, each the fastest we measured on the board
([numbers and what else we tried](AI-BENCHMARKS.md)):

- **Chat (LLM):** Qwen3.8-27B with llama.cpp: about 27 tokens/s (31 on code), 32k context.
- **Faster chat (LLM):** Inkling-2-Mini with a llama.cpp fork: about 47 tokens/s, 32k context (59 tokens/s on a PS5 Pro).
- **Biggest model (PS5 only):** Qwen3.8-Flash-Next, 125B, streamed from the internal M.2: about 42 tokens/s on a PS5 Pro.
- **Images:** ComfyUI with SDXL-Lightning: a 1024×1024 image in about 20 s.

Each needs most of the board's memory, so run one at a time.

## Kernel parameters

| Parameter | Why |
|---|---|
| `ttm.pages_limit=3670016` | Lets the GPU use up to 14 GB of the memory (the default is about half). Without it the 27B model does not fit. It helps the PS5 emulator too. |
| `amdgpu.sched_policy=2` | Needed for ROCm (ComfyUI), see [ROCm](ROCM.md). Not needed for chat. |

**On the PS5 both are already set** in this image's `cmdline.txt` (on the `boot` partition, `/boot/efi/cmdline.txt`): check with `cat /proc/cmdline`. The BC-250's measurements below also used `amdgpu.bc250_cc_write_mode=3` (unlocks all 40 CUs of that board); that option is BC-250 only and not in the PS5 kernel.

## Before you start: server mode

The GPU shares the memory with the system (about 15 GiB on a PS5 Pro). Stop Gaming Mode (or the
desktop) while you use these models, for example over SSH:

```bash
sudo systemctl stop getty@tty1           # stop Gaming Mode / the desktop and Steam
sudo systemctl start getty@tty1          # back to Gaming Mode (or restart the PS5)
```

The PS5 kernel sets the GPU clock itself (ps5-gpufreq); the BC-250 needs a separate governor service
for that, the PS5 doesn't. [Boost](../README.md#7-extras-boost-fan-and-video) (`sudo ps5-boost on`)
raises the CPU and GPU maximum clocks.

If you work over SSH, also run this once, or your services stop when you log out:

```bash
sudo loginctl enable-linger $USER
```

## Chat: Qwen3.8-27B

```bash
sudo pacman -S llama-cpp ggml-vulkan
mkdir -p ~/models && cd ~/models
curl -LO https://huggingface.co/unsloth/Qwen3.8-27B-GGUF/resolve/main/Qwen3.8-27B-UD-IQ3_XXS.gguf   # 10.9 GB
curl -LO https://huggingface.co/unsloth/Qwen3.8-27B-GGUF/resolve/main/MTP/mtp-Qwen3.8-27B-Q4_0.gguf  # 1.4 GB
```

Create `~/.config/systemd/user/llama-server.service`:

```ini
[Unit]
Description=llama.cpp server (Qwen3.8-27B)

[Service]
ExecStart=/usr/bin/llama-server --model %h/models/Qwen3.8-27B-UD-IQ3_XXS.gguf \
    --n-gpu-layers 99 --flash-attn on --cache-type-k q8_0 --cache-type-v q8_0 \
    --ctx-size 32768 --parallel 1 --jinja --host 0.0.0.0 --port 8080 \
    --spec-type draft-mtp --model-draft %h/models/mtp-Qwen3.8-27B-Q4_0.gguf \
    --n-gpu-layers-draft 99 --spec-draft-n-max 2
Restart=on-failure

[Install]
WantedBy=default.target
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now llama-server
```

Open `http://<board-ip>:8080` for a chat page. Port 8080 is also an
OpenAI-compatible API (`/v1/chat/completions`) for Open WebUI, SillyTavern or
your own scripts.

- Qwen3.8 thinks before it answers. With an API, give it `max_tokens` of 2000+
  or the answer may come back empty, or turn thinking off per request with
  `"chat_template_kwargs": {"enable_thinking": false}`.
- Like any local model it can state wrong facts with confidence. Check what matters.
- The `--spec-type draft-mtp` lines use the model's multi-token prediction
  heads to guess 2 tokens ahead. It doesn't change the answers, and it makes
  replies about 18% faster (more on code, less on prose). It uses 1.3 GB more memory: if
  you need that memory, remove those two lines and the trailing `\` before them.
- Use the Vulkan backend as above: it is faster here than ROCm and needs no extra setup.
- Want it faster rather than smarter? `Qwen3.5-9B-Q4_K_M.gguf` (5.7 GB, from
  `unsloth/Qwen3.5-9B-GGUF`) runs at about 60 tokens/s with the same service file.

### More context or a better quant

The setup above is the fastest. If you'd rather have a longer context or a
better quant (more accurate answers), drop the MTP lines and use one of these
instead. Each was tested with the context filled to 90%:

| Model file (from `unsloth/Qwen3.8-27B-GGUF`) | `--ctx-size` | Speed, short / full context |
|---|---:|---:|
| `Qwen3.8-27B-UD-IQ3_XXS.gguf` (10.9 GB) | `98304` | 24 / 17 tokens/s |
| `Qwen3.8-27B-UD-IQ3_S.gguf` (12.0 GB) | `65536` | 23 / 18 tokens/s |
| `Qwen3.8-27B-UD-IQ4_XS.gguf` (14.4 GB) | `16384` | 21 / 20 tokens/s |

Add `--ctx-checkpoints 1 --cache-ram 0` to the `ExecStart` line. By default
llama-server keeps up to 32 snapshots of 150 MB each, and up to 8 GB of old
prompts in RAM, which the GPU needs here.

Don't go above these sizes. A context that doesn't fit doesn't just fail to start: the
kernel then runs out of memory and kills other services (network, SSH, audio)
before llama-server. Sometimes the whole board hangs and needs a power cycle.

### Even more context: trim the vocabulary

Qwen3.8 knows about 248,000 tokens for all the world's scripts. If you only
chat in English and other Latin-alphabet languages, you can remove the rest from
the model file. That frees about 0.5–0.7 GB for context and makes replies about
3% faster. With the [ASCII-Condensed prune tools](https://github.com/bsaleh03/ASCII-Condensed-prune-tools):

```bash
git clone https://github.com/bsaleh03/ASCII-Condensed-prune-tools ~/prune-tools
python -m venv ~/prune-venv && ~/prune-venv/bin/pip install gguf numpy
cd ~/models
~/prune-venv/bin/python ~/prune-tools/prune_vocab.py \
    Qwen3.8-27B-UD-IQ3_S.gguf Qwen3.8-27B-UD-IQ3_S-P2.gguf --policy P2
```

Use `--policy P2` (ASCII plus accented Latin letters). With the default (ASCII
only) or `P1M`, words like "café" or "België" came out garbled in our tests. The
model can still spell a removed character byte by byte, but it often picks the
wrong bytes. With `P2` the same goes for emoji, Chinese, Cyrillic, Greek and math
symbols.

| Trimmed model file | `--ctx-size` | Speed, full context |
|---|---:|---:|
| `Qwen3.8-27B-UD-IQ3_S-P2.gguf` (11.4 GB) | `81920` | 17 tokens/s |
| `Qwen3.8-27B-UD-IQ4_XS-P2.gguf` (13.7 GB) | `24576` | 19 tokens/s |

Same flags as in the table above (`--ctx-checkpoints 1 --cache-ram 0`, no MTP).
These two were tested with the VRAM carve-out set to 256 MB
([details](AI-BENCHMARKS.md#vram-carve-out-256-mb)), which leaves the system
250 MB more RAM. With the default 512 MB, use one step less (`73728` and `16384`).

### Heat: long prompts

Reading a long prompt (tens of thousands of tokens, such as a long document
or a big codebase) keeps the GPU at full power for minutes, and the GPU's
voltage regulators (VRMs) get hot. With small VRM heatsinks we measured
92 → 120 °C in 80 seconds. The board switches itself off at 140 °C. Normal chat is fine: short prompts don't load the GPU long
enough, and the VRMs cool down within seconds between replies.

Check with `sensors` (`GPU VRM Temp`). If it goes above about 110 °C, add
airflow over the VRM heatsinks, or don't feed it very long prompts.

## Faster chat: Inkling-2-Mini

[Inkling-2-Mini](https://huggingface.co/unsloth/Inkling-2-Mini-GGUF) (Thinking Machines) is a
26B mixture-of-experts model: only about 3.4B of its parameters work on each token, so it runs about
twice as fast as Qwen3.8-27B at a similar file size. On a PS5 Pro: **686 tokens/s reading a prompt and
59 tokens/s writing**.

The packaged llama.cpp can't run it yet (the `inkling2` architecture is not in it). Trecto34's
[llama-inkling2-vulkan](https://github.com/Trecto34/llama-inkling2-vulkan) is llama.cpp with that
support and Vulkan shaders written for this model. Build it yourself:

```bash
sudo pacman -S --needed cmake ninja git vulkan-headers spirv-headers shaderc glslang
git clone https://github.com/Trecto34/llama-inkling2-vulkan.git ~/llama-inkling2-vulkan
cd ~/llama-inkling2-vulkan
git checkout e734ca0          # v0.2-vulkan, the version measured here
cmake -B build -G Ninja -DGGML_VULKAN=ON -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release
cmake --build build --target llama-server llama-cli llama-bench

mkdir -p ~/models && cd ~/models
curl -LO https://huggingface.co/unsloth/Inkling-2-Mini-GGUF/resolve/main/Inkling-2-Mini-UD-IQ3_XXS.gguf   # 11.7 GB
```

Stop Gaming Mode first ([server mode](#before-you-start-server-mode)): the model needs about 12 GB.
Run it with the same kind of service file as above, for example
`~/.config/systemd/user/llama-inkling.service`. Stop the Qwen3.8 service first: only one model fits at a time.

```ini
[Unit]
Description=llama.cpp server (Inkling-2-Mini)

[Service]
ExecStart=%h/llama-inkling2-vulkan/build/bin/llama-server \
    --model %h/models/Inkling-2-Mini-UD-IQ3_XXS.gguf \
    --n-gpu-layers 99 --flash-attn on --cache-type-k q8_0 --cache-type-v q8_0 \
    --ctx-size 32768 --ubatch-size 128 --parallel 1 --ctx-checkpoints 1 --cache-ram 0 \
    --host 0.0.0.0 --port 8080
Restart=on-failure

[Install]
WantedBy=default.target
```

**Set `--ubatch-size` with the context size.** In this build the GPU's work buffer grows with the
context *times* the micro-batch, not the KV cache (that is small: 136 MB at 8k). Pick a row:

| `--ctx-size` | `--ubatch-size` | Prompt speed | Memory left |
|---:|---:|---:|---:|
| `8192` | `512` (default) | 676 t/s | 1.5 GB |
| `16384` | `256` | 514 t/s | 1.6 GB |
| **`32768`** | **`128`** | **374 t/s** | **1.5 GB** |
| `65536` | `64` | 242 t/s | 1.4 GB |

Each row starts and answers a short request; the context was not filled with text. The micro-batch
only changes how fast prompts are read: writing stays at about 59 tokens/s.

- With the default micro-batch, 16k did not fit: the kernel killed another program
  (`plasma-welcome`) for memory before llama-server gave up.

- It thinks before it answers by default, so give API requests room (`max_tokens` 1000+).
- Like any local model it can state wrong facts with confidence. Check what matters.

## Biggest model: Qwen3.8-Flash-Next (PS5 only)

[Qwen3.8-Flash-Next](https://huggingface.co/Qwen/Qwen3.8-Flash-Next) is a 125B mixture-of-experts model: far
bigger than the memory, so it can't run with llama.cpp here. LaRazaDelSol's
[AIEngineOnSmallUniMem](https://github.com/LaRazaDelSol/AIEngineOnSmallUniMem) is an engine written for the PS5:
the small always-used part of the model (2.7 GB) stays in memory, and the experts each token needs are read from
the internal M.2 drive as it goes, with a 10 GB cache of the ones used most. On a PS5 Pro: **40-44 tokens/s
writing** once its cache is warm (20-35 on the first answers) and **about 360 tokens/s reading** a long prompt.
Measured on this image: [benchmarks](AI-BENCHMARKS.md#llm-qwen38-flash-next-ps5-pro).

What it needs:

- **The internal M.2 drive** with about **350 GB free** while it is set up (about 200 GB stays used). The setup downloads
  about 470 GB, most of it deleted again as it goes. A USB drive is too slow.
- **`kho=off udmabuf.size_limit_mb=16384`** in the boot options. New images have them; on an older install the
  [updater](../README.md#5-updating) adds them (or add them to the end of the single line in
  `/boot/efi/cmdline.txt`), then restart. Without `kho=off` the kernel keeps 1.5 GB aside that the engine can't
  use, and it runs out of memory at start (measured). Check with `grep -o kho=off /proc/cmdline`.
- **A few hours** for the download and conversion. Everything below runs as your normal user over SSH, except
  where it says `sudo`.

### 1. Build the engine

```bash
sudo pacman -S --needed cmake ninja git vulkan-headers glslang shaderc \
    python-tokenizers python-jinja python-huggingface-hub
mkdir -p ~/ps5lm && git clone https://github.com/LaRazaDelSol/AIEngineOnSmallUniMem.git ~/ps5lm/src
cd ~/ps5lm/src && git checkout bf7d21c          # the version measured here
cmake -S runtime -B ~/ps5lm/build14 -G Ninja -DCMAKE_BUILD_TYPE=Release -DPS5LM_BUILD_BENCH=OFF
cmake --build ~/ps5lm/build14 --target flash_decode ps5lm_shaders pack_convert
```

Skip the engine's own "boot modes" step (`ps5lm-min`): it needs kernel patches of its own and restarts that the
PS5 loader doesn't do. The service in step 3 does the same job here.

### 2. Download and convert the model

Run these one after the other, each in a unit of its own, so they keep going when you log out. Each one can be
started again if it stops: it continues where it was.

```bash
M=~/ps5lm/model; mkdir -p $M; cd ~/ps5lm/src/runtime/tools

# tokenizer, chat template, config and shard list of the original model
hf download Qwen/Qwen3.8-Flash-Next tokenizer.json tokenizer_config.json chat_template.jinja config.json \
    model.safetensors.index.json --local-dir $M
cp $M/model.safetensors.index.json $M/index.json      # the converter looks for this name

# the original weights (131 parts, 360 GB, each deleted once converted): about an hour after the download
systemd-run --user --unit=fn-convert -d python3 convert_hf.py --out $M --bin ~/ps5lm/build14/pack_convert
journalctl --user -u fn-convert -f                   # "ALL DONE" at the end (Ctrl+C stops watching only)

# the experts in 3.18 bits (EXL3, 106 GB), packed for the engine
systemd-run --user --unit=fn-exl3 -d sh -c "hf download turboderp/Qwen3.8-Flash-Next-exl3 \
    --revision 3.18bpw_h6_ng8 --local-dir ~/ps5lm/dl && python3 s15/pack_exl3.py ~/ps5lm/dl $M --delete-shards"
journalctl --user -u fn-exl3 -f                      # "done" at the end
```

`pack_exl3.py` (at `bf7d21c`) doesn't write the small index the next step and the engine read
(`experts_exl3.txt`). Make it from the pack's `.json`, then add the MTP layer (used to guess several tokens at once):

```bash
python3 - <<'PY'
import json, os
D = os.path.expanduser("~/ps5lm/model"); m = json.load(open(D + "/experts_exl3.json"))
with open(D + "/experts_exl3.txt", "w") as f:
    f.write("# layer K2 slot_bytes base span_bytes\n")
    for l in range(len(m["base"])):
        f.write(f"{l} {round(2 * m['K'][l])} {m['slot_bytes'][l]} {m['base'][l]} {m['span_bytes'][l]}\n")
PY
python3 s15/pack_exl3_mtp.py $M
```

The model's chat template now carries `{% generation %}` markers (only used for training): the engine's server
stops at them. Remove those two lines (the original stays as `.orig`):

```bash
cp -n $M/chat_template.jinja $M/chat_template.jinja.orig
sed -i -E '/^[[:space:]]*\{%-?[[:space:]]*(end)?generation[[:space:]]*-?%\}[[:space:]]*$/d' $M/chat_template.jinja
```

**Optional, a self-test:** the 2.68-bit experts (40 GB more, read straight from Hugging Face, about 8 minutes)
and the engine's smoke test, which checks that it writes exactly the author's reference answer:

```bash
python3 s17/fetch_pack_exl3.py 2.68bpw_h6_ng8 $M experts_exl3_268
python3 s15/pack_exl3_mtp.py $M experts_exl3_268 --nonexpert $M/exl3_nonexpert.safetensors
sudo systemctl stop getty@tty1                       # Gaming Mode off (memory)
sudo env HOME=$HOME bash ~/ps5lm/src/scripts/console/smoke.sh
sudo systemctl start getty@tty1                      # Gaming Mode back
```

It should end with `PASS` (on this image: `md5 18179c0e1f51 PASS`, 28 tokens/s on a cold start).

**Cleanup:** the converter also writes two packs of a simpler format that the setup here doesn't use (103 GB):

```bash
rm ~/ps5lm/model/experts_q4.pack ~/ps5lm/model/experts_q2.pack
```

### 3. The server

A system service (the engine runs as root: it reserves huge pages and locks its memory). Starting it stops
Gaming Mode, stopping it brings Gaming Mode back. If your user isn't `steam`, change `U=`:

```bash
sudo tee /etc/systemd/system/flash-next.service >/dev/null <<'EOF2'
[Unit]
Description=Qwen3.8-Flash-Next (AIEngineOnSmallUniMem), OpenAI API on port 8081
# Starting it stops Gaming Mode (the model needs nearly all memory); stopping it brings Gaming Mode back.
Conflicts=getty@tty1.service
After=getty@tty1.service network-online.target

[Service]
Environment=U=/home/steam
ExecStart=/usr/bin/python3 ${U}/ps5lm/src/runtime/tools/ps5lm_server.py --model ${U}/ps5lm/model \
    --bin ${U}/ps5lm/build14/flash_decode --shaders ${U}/ps5lm/build14/shaders --bits 3 --port 8081 \
    --pool-gib 10.25 --max-ctx 65536 --spec 3 --pld 4 --kv k4v4 --kv-base 8192 --prefill-chunk 8192 \
    --wide-slice 512 --route-mtp 1 --route-bias 1 --prefetch-max 4 --route-pf --pool-reserve-mib 256 \
    --kv-store ${U}/ps5lm/sessions
ExecStopPost=-/usr/bin/systemctl --no-block start getty@tty1.service
KillMode=mixed
TimeoutStopSec=60
OOMScoreAdjust=1000
EOF2
sudo systemctl daemon-reload
sudo systemctl start flash-next          # ready after about a minute
sudo systemctl stop flash-next           # back to Gaming Mode
```

Don't `enable` it: it would stop Gaming Mode at every start. Try it:

```bash
curl http://<ps5-ip>:8081/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"What is the capital of Australia?"}],"max_tokens":200}'
```

Any program that speaks the OpenAI API works with `http://<ps5-ip>:8081/v1` (the engine's own chat page isn't
set up here).

- **`--pool-gib 10.25`:** the engine's `auto` takes nearly all free memory, and then it can fail with
  `Not enough memory for command submission`: the GPU can map at most 14 GB here (`ttm.pages_limit=3670016`),
  for everything together. 10.25 leaves room for an 11k-token prompt (measured).
- **`--max-ctx 65536`:** what was tried here; the engine can go to 262144 and grows the memory for it as the
  conversation does, taken from the expert cache (slower).
- **`--route-bias 1 --route-pf`** (and `--prefetch-max 4`) make it prefer experts that are already in memory: the
  answers change a little, and it writes 1.8x as fast (measured: 39.8 vs 22.4 tokens/s on a cold start).
  Remove those three for the model's exact choice of experts.
- Conversations are kept on the drive (`~/ps5lm/sessions`, up to 16 GB): a follow-up question doesn't read the
  whole conversation again, even after a restart.
- It thinks before it answers by default; `"chat_template_kwargs": {"enable_thinking": false}` turns that off.
- Like any local model it can state wrong facts with confidence. Check what matters.

## Images: ComfyUI with SDXL-Lightning

Needs `amdgpu.sched_policy=2` (see [Kernel parameters](#kernel-parameters)).

```bash
sudo pacman -S bc250-pytorch
bc250-pytorch-check                  # should end with "OK"

git clone https://github.com/comfyanonymous/ComfyUI ~/ComfyUI
cd ~/ComfyUI
/opt/bc250-pytorch/bin/python3 -m venv --system-site-packages venv
venv/bin/pip install -r requirements.txt

curl -L -o models/checkpoints/sd_xl_base_1.0.safetensors \
  https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0/resolve/main/sd_xl_base_1.0.safetensors     # 6.9 GB
curl -L -o models/loras/sdxl_lightning_8step_lora.safetensors \
  https://huggingface.co/ByteDance/SDXL-Lightning/resolve/main/sdxl_lightning_8step_lora.safetensors         # 0.4 GB
```

The clock governor can't see this kind of GPU work and would leave the GPU at
its lowest clock, so set a fixed clock while you generate images, then start
ComfyUI:

```bash
sudo busctl --system set-property com.cyanskillfish.Governor /com/cyanskillfish/Governor \
  com.cyanskillfish.Governor.PerformanceMode Enabled b true
sudo busctl --system call com.cyanskillfish.Governor /com/cyanskillfish/Governor \
  com.cyanskillfish.Governor.PerformanceMode SetFixedFrequency u 2100    # or your config's max

cd ~/ComfyUI
PYTORCH_TUNABLEOP_ENABLED=1 PYTORCH_TUNABLEOP_FILENAME=$HOME/ComfyUI/tunableop.csv \
  venv/bin/python main.py --listen 0.0.0.0
```

Open `http://<board-ip>:8188`. In the default workflow:

1. *Load Checkpoint*: `sd_xl_base_1.0.safetensors`.
2. Add a **LoraLoaderModelOnly** node between *Load Checkpoint* and *KSampler*,
   with `sdxl_lightning_8step_lora.safetensors`.
3. *KSampler*: steps **8**, cfg **1.0**, sampler **euler**, scheduler **sgm_uniform**.
4. *Empty Latent Image*: **1024 × 1024**.

**The first image takes about 8 minutes**: TunableOp measures the GPU's
fastest settings for every size the model uses. They are saved (as
`tunableop0.csv`) when you stop ComfyUI with Ctrl-C, so do that rather than
killing it; after that every image takes about 20 s, also after a restart.
After a `bc250-pytorch` update the first image is slow once more.

When you are done, stop ComfyUI with **Ctrl-C** and give the clock back to the
governor:

```bash
sudo busctl --system set-property com.cyanskillfish.Governor /com/cyanskillfish/Governor \
  com.cyanskillfish.Governor.PerformanceMode Enabled b false
```

Don't `pip install torch` into the venv, and remove any line in a custom node's
requirements that pins a torch version: that would replace the BC-250 build
with a CUDA one.

![SDXL-Lightning, 8 steps](images/ai/sdxl-lightning-8step.jpg)

*"a cozy cabin in a snowy pine forest at dusk, warm light in the windows,
photorealistic, detailed": SDXL-Lightning, 8 steps.*
