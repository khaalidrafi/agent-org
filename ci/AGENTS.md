
# Global Instructions for LLM Agents


## Environment

-   Guix (`master`) on an ASUS X451MA (Intel Celeron, 4 GB RAM). Guix first; Nix as fallback for missing packages.
-   Be careful with binaries: Guix does not use FHS. Verify that installed binaries work (no "file not found" errors).
-   `guix system` / `guix home reconfigure` recompiles the local `brix` channel; be patient and never run two instances in parallel. Use `-v` for progress.
-   Search with modern tools, always: `rg` (not `grep -r`), `fd` (not `find`), and `rg --files` / `fd -t f` for listings. They are faster, they respect `.gitignore`, and they do not stall the machine scanning `/gnu/store`. Never let `find /` or `grep -r /` near a path run: bound searches with `-d`/`--max-depth` and exclude `/gnu/store`, `~/.guix-home`, `~/.cache` etc.


## Search tools

-   Locate files: `fd -t f PATTERN [PATH]` (e.g. `fd -t f -e el acp`).
-   Search contents: `rg PATTERN [PATH]` with `--glob`, `-n`, `-C 3`, `-l`, `--files-without-match`.
-   List a tree: `rg --files PATH` or `fd -t f . PATH`, not `find`/`ls -R`.


## System load

-   Low‑spec machine: avoid heavy builds, use `-j1` for parallel limits.
-   Monitor load with `free`, `htop`, etc.
- BEWARE OF FREEZING THIS MACHINE!

## Guix build/test policy (this machine)

-   Source‑based packages: NEVER build locally — this is absolute. Only `guix build -L . --dry-run PKG` here (evaluation only -- catches typos, unbound variables, bad hashes, unresolvable inputs without compiling or downloading). CI (GitHub Actions) is what actually builds source packages.
-   NO source-build workarounds either: NEVER reproduce a source build locally to debug it — no cloning the repo + `bun install` / `pnpm install` / `npm install` + compiling, not even with nice/ionice. A dependency install of a real project (thousands of packages, GBs) IS a heavy build on this machine. Debug from CI logs only.
-   NEVER `guix install` a source package. Only prebuilt `*-bin` channel packages may ever be installed here.
-   `*-bin` packages (repackaged vendor binaries): MUST build, install and actually run them locally. Their build is just a download + repack, cheap enough for this machine, and only running them proves the wrapping/interpreter/`.desktop` works.
-   After installing a `*-bin`, run the real binary (not just `--help`) and check for "file not found"/missing‑shared‑library errors, since Guix is not FHS.


## Code

-   Keep code simple, well‑commented, and short. Don't overengineer. Work FAST!

-   We consider code review to be VERY important for AI-generated code. Do WHATEVER is needed to facilitate that. Ask/suggest user to install tools that will help him review your code. And, also ask the user to review some of your code right away if it's crucial during development to review that portion of code. Also, document what to review in AI-REVIEW.org with a TODO tree.

-   Don't create any technical debt for future human development, or keep it the lowest. Add clear comments that help understand and debug code. Add descriptive commit messages that clearly explain your code and algorithm. Add to commit messages what you couldn't write in code comments since they can't be long. Your code MUST be easy to handle for future human developers. It should be possible to review, debug and build upon without hassle. Also, remind me to review important works which might be harder to review/debug in future for technical debt.
-   When developing Emacs packages, read the Emacs, Elisp and (if relevant) Org manuals, since LLMs are generally less skilled in Emacs.

-   I wanna learn software development for the agentic era. I wish to learn skills that will help me make money, preferrably through business/entrepreneurship, but also through jobs. You will help me learn as I develop with you. Explain important concepts briefly at the time of development. Remind me to learn, read or review important concepts and tell me how better to prompt you or suggest corrections to my prompts at the time of development. Suggest what to do for learning while developing.

-   Always commit with your model identity as author in this format:
`MODEL <MODEL@PROVIDER>` (e.g. "Qwen 2.5 Coder <qwen-2.5-coder@b.ai>", or if you're a built-in model inside the agent/harness, "Qwen3.8-Flash <qwen3.8-flash@qoder.com>").

-   Always include both the agent/harness and the user as co-authors using Git trailers at the end of the commit message. For example:

        Co-authored-by: OMP <omp@omp.sh>
        Co-authored-by: Khalid Rafi <khaalidrafi@gmail.com >
        
    Here, OMP is the name of the harness/agent as an example. You'll use the name of the agent/harness you're working in, not the model name.


- DON'T commit changes made by other sessions / agents as yourself. Ask if such uncommitted changes need to be handled.

- BEWARE! I want commits to be very accurate since I'll use them for benchmarking. So, co-ordinate with me as necessary to confirm you're committing as my order.

-   Follow project conventions; run tests/lint when available.
-   Ask before any destructive or system‑wide action.
-   ****READ THE DOCS FIRST**** – upstream manuals, Guix manual, and source, if needed, before writing code.
-   $DOTFILES is the Guix‑managed source tree at `~/home-config/dotfiles`. Edit files under $DOTFILES for configs, never the live `~/` copies. After changes, remind the user to run `guix home reconfigure`.

-   Always commit -- it documents AI-generated code.  But, never
    commit directly to `main`. `ai/main` is your main branch. Use a
    separate git branch `ai/<topic>` for any long multi-step work.

-   NEVER procrastinate commits by piling up a stack of uncommitted work:
    commit as soon as each small step is done and verified, so every commit
    stays small enough to review in one sitting and contains changes from
    ONE model only.  A commit that mixes several agents' edits, or several
    unrelated features at once, is model change pollution -- the benchmark
    depends on each commit being attributable to one model's work.  So:
    commit early, commit small, commit often.

- Start fresh projects with `git init` and `ai/main` branch.

-   Prefer Org mode over Markdown unless it causes issues.


## Plans, todos and workflow

-   Always start any large task with a clear step‑by‑step plan and write tests in `tests/` directory before implementation. Besides planning, carry out user's orders, if any, instead of showing him the plan and asking him to do. Always carry out user's orders and before carrying out, plan yourself! That's the instruction.
-   Use the `todo` tool to track each atomic action; keep it updated.
-   Execute ****one**** step at a time, verify, then report before proceeding.
- Break each task into small and easy steps in your plan/TODOs.
-   Test well, including by using it directly, e.g., explicitly running a program and testing if your code worked or browsing your developed website directly with available means just as a real user would. This way, you'll catch bugs before the user. After you have confirmed verification and tested strictly, tell the user how to test it by usage once your task is done.
-   When working on Emacs Lisp, always load your changes when your're ready to ask user to test, via `emacsclient`.
-   When loading Emacs Lisp, use `emacs --batch --eval` to validate before loading into a live session.
- Always use `use-package` when providing Emacs package setup code.
- Please, always judge yourself with the Jev AI (using TypeSafe skill and `TYPESAFE_API_KEY`) if you've followed ALL my instructions, as I gave you in global and local AGENTS.md besides those in my prompts, completely and accurately.
- Never modify `$DOTFILES/.emacs.d/`, and never run `guix home reconfigure` without my EXPLICIT permission.
 Put works that need to persist under ~/.agents-work/.

## Responses

-  Use simple language in your response instead of complicated jargon. Keep your responses short, concise and straightforward. DON'T TALK TOO MUCH!

-   ENGLISH ONLY, ALWAYS: every reply, report, commit message, code comment and document you produce MUST be in English. NEVER write in Chinese or any other language. If a tool, gateway, model provider or upstream service emits non-English text (e.g. a provider error string), do NOT forward it raw — translate it and report the substance in English.


## Client detection

-   If INSIDE_EMACS is non-zero, prefer Emacs‑aware actions (e.g. `emacsclient` calls). Otherwise, plain shell. And, ask questions to the user, if any, via `emacsclient`, with `y-or-n-p` for yes/no questions and `read-from-minibuffer` for others.

