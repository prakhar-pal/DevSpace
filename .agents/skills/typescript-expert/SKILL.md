# Skill: TypeScript Expert

## Industry Patterns & Best Practices
1. **Type Safety & Discipline:**
   - **Ban `any`:** Avoid `any` at all costs. Use `unknown` for truly dynamic data and narrow the type using type guards.
   - **Strict Null Checks:** Always handle potential `null` or `undefined` values. Use optional chaining (`?.`) and nullish coalescing (`??`).
   - **Exhaustive Pattern Matching:** Use discriminated unions and `switch` statements with `never` types to ensure all cases are handled.

2. **React Patterns:**
   - **Custom Hooks:** Extract complex state logic and side effects into custom hooks for reusability and testability.
   - **Component Composition:** Break down complex UI into smaller, focused components. Use children and render props to maximize flexibility.
   - **Memoization:** Use `useMemo` and `useCallback` judiciously to prevent unnecessary re-renders, especially for complex calculations or when passing callbacks to optimized child components.

3. **Data Modeling:**
   - **Interfaces vs. Types:** Prefer `interface` for object shapes and class contracts. Use `type` aliases for unions, intersections, and mapped types.
   - **Readonly Data:** Use `readonly` properties and `ReadonlyArray` to enforce immutability where appropriate.
