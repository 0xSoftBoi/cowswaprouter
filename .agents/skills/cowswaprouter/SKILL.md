```markdown
# cowswaprouter Development Patterns

> Auto-generated skill from repository analysis

## Overview
This skill teaches you the core development patterns and conventions used in the `cowswaprouter` Python codebase. You'll learn about file naming, import/export styles, commit patterns, and how to approach testing and common workflows in this repository.

## Coding Conventions

### File Naming
- **PascalCase** is used for file names.
  - Example: `SwapRouter.py`, `OrderHandler.py`

### Import Style
- **Relative imports** are preferred.
  - Example:
    ```python
    from .OrderHandler import OrderHandler
    ```

### Export Style
- **Named exports** are used (explicitly exporting classes, functions, etc.).
  - Example:
    ```python
    class SwapRouter:
        ...
    ```

### Commit Patterns
- Commit messages are **freeform** (no strict prefixes).
- Average commit message length: **84 characters**.
  - Example:  
    ```
    Add support for multi-hop swaps and improve error handling in router logic
    ```

## Workflows

### Adding a New Feature
**Trigger:** When you need to implement a new feature or module  
**Command:** `/add-feature`

1. Create a new file using PascalCase (e.g., `NewFeature.py`).
2. Implement your feature using relative imports for dependencies.
3. Export your main classes/functions explicitly.
4. Write a descriptive, freeform commit message summarizing the feature.

### Refactoring Existing Code
**Trigger:** When improving or restructuring existing code  
**Command:** `/refactor-code`

1. Identify the file(s) to refactor.
2. Update code using relative imports and maintain PascalCase naming.
3. Ensure exports remain named and explicit.
4. Commit changes with a clear, descriptive message.

### Writing Tests
**Trigger:** When adding or updating tests  
**Command:** `/write-test`

1. Create or update a test file with the `.test.ts` extension (TypeScript).
2. Write test cases covering the relevant Python logic.
3. (Testing framework is unknown; follow existing patterns if present.)
4. Commit with a message describing the test coverage.

## Testing Patterns

- Test files follow the pattern `*.test.ts` (TypeScript).
- The specific testing framework is **unknown**; review existing test files for guidance.
- Place tests in appropriately named files corresponding to the module under test.

## Commands
| Command        | Purpose                                      |
|----------------|----------------------------------------------|
| /add-feature   | Scaffold and implement a new feature/module  |
| /refactor-code | Refactor or improve existing code            |
| /write-test    | Add or update tests for Python modules       |
```
