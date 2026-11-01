---
name: offload
description: Offload large-input, small-output work to free LLM APIs through the `offload` CLI, saving Claude's own context and quota. Use when asked to summarize this log, say what is in this file, extract the errors from a log, translate this file, transcribe this audio, digest a long transcript, or read a huge file (over 200 lines) where a short result is enough; not for decisions, code review, or anything that needs repository context.
---
# offload

Hand the big input to a free model, keep only the short answer.

## Commands
- `offload ask "INSTRUCTION" FILE` — reads FILE, prints the answer on stdout; the provider and model go to stderr.
- `cmd | offload ask "INSTRUCTION" -` — same, input from stdin. Without a second argument no input is read.
- `offload transcribe FILE -- -F language=ru` — Whisper via Groq; pass the language when known.
- `offload doctor` — which keys exist and whether each provider answers.

## Routing and limits
- Inputs up to 20K characters go to Groq (gpt-oss-120b, instant; 8K tokens/minute, 1,000 requests/day). Larger inputs go to NVIDIA NIM (nemotron-3.5-lightning, no token cap, about 40 requests/minute). A failing provider falls through to the next one.
- Hard cap 400K characters (about 100K tokens): narrow first with grep, head or tail, then offload.
- If every provider is down, `ask` exits 1. Then Read only the exact range you need with offset/limit.

## Writing the instruction
- State the answer language and format: "In Russian, 5 bullet points", "JSON list of error messages". Nemotron answers in English unless told otherwise.
- Ask only for what you need. One instruction, one result.
- Never pass secrets, `.env` files or credentials: the input leaves the machine.
- Verify numbers, names and paths in the answer before relying on them. Free models invent details.
