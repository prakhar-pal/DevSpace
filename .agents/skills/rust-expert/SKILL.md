# Skill: Rust Expert

## Industry Patterns & Best Practices
1. **Idiomatic Safety & Logic:**
   - **Error Handling:** Avoid `.unwrap()` and `.expect()` in production code. Use the `?` operator and custom error types (via crates like `thiserror` or `anyhow`) for robust error propagation.
   - **Pattern Matching:** Leverage `match` statements extensively over `if/else` chains to ensure exhaustive handling of enums and edge cases.
   - **Defensive Programming:** Use safe abstractions and avoid `unsafe` blocks unless absolutely necessary for performance or FFI.

2. **Ownership & Borrowing:**
   - **Borrowed Types in APIs:** Prefer `&str` over `&String`, `&[T]` over `&Vec<T>`, and `&Path` over `&PathBuf` for function arguments to maximize flexibility and minimize allocations.
   - **Lifetimes:** Use explicit lifetimes only when necessary; rely on lifetime elision rules where possible to keep code clean.

3. **Architecture & Performance:**
   - **Newtype Pattern:** Wrap primitive types in single-field structs (e.g., `struct WorkspaceId(String);`) to enforce domain-specific type safety and prevent logic errors.
   - **Iterators:** Use iterator adapters (`map`, `filter`, `fold`) instead of manual loops for cleaner, often more performant code.
   - **Zero-Cost Abstractions:** Design APIs that leverage Rust's zero-cost abstractions, avoiding unnecessary `Box`, `Rc`, or `Arc` overhead unless dynamic sizing or shared ownership is required.
   - **Concurrency:** Safely share state across threads using `Arc<Mutex<T>>` or channels (`mpsc`), adhering strictly to Rust's concurrency guarantees.
