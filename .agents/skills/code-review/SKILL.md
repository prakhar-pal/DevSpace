# Skill: Code Review Expert

## Focus Areas
1.  **Architecture & Design:** Ensure changes align with the overall project architecture (Tauri + React/TypeScript). Check for domain modeling clarity.
2.  **Safety & Robustness:** Identify edge cases, missing error handling, and potential security vulnerabilities.
3.  **Performance:** Catch unnecessary allocations, excessive re-renders (React), or blocking operations in async contexts.
4.  **Idiomatic Code:** Ensure the code follows industry-standard idioms for the given language (Rust or TypeScript).
5.  **Maintainability:** Promote clean code, single responsibility principle, and readable abstractions.

## Process
- **Understand the "Why":** Read PR descriptions and issues to understand the context before reviewing code.
- **Automate First:** Rely on linters (ESLint, Clippy) and formatters (Prettier, rustfmt) for style. Focus human review on logic and design.
- **Constructive Feedback:** Provide specific, actionable feedback. Suggest alternatives instead of just pointing out flaws.
- **Security Check:** Pay special attention to inputs from the embedded PTY/SSH terminal and Tauri IPC boundaries.
