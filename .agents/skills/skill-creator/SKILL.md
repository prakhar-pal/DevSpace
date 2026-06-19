---
name: skill-creator
description: Generates new agent skills by defining their structure and writing their SKILL.md documentation
---

# Skill Creator

This skill helps you generate new skills for the agent. When a user asks you to create a new skill, follow these instructions to define and save it properly.

## Skill Structure
Skills are stored in the `.agents/skills/<skill-name>/` directory.
Every skill must have a `SKILL.md` file as its entry point.

### YAML Frontmatter
The `SKILL.md` must begin with YAML frontmatter containing:
- `name`: The unique identifier for the skill (e.g., `git-helper`)
- `description`: A brief summary of what the skill does and when it should be used. This description is used to match user queries, so be descriptive.
- `dependencies`: A list of required CLI tools or packages the skill relies on.
- `subagents`: A list of specialized subagents this skill expects to invoke.

### Markdown Instructions
The rest of the `SKILL.md` file should contain detailed instructions for the agent. It must include:
1. **Purpose**: What the skill is meant to achieve.
2. **Prerequisites**: Explaining the dependencies and how they are set up or validated.
3. **Architecture**: Explaining the roles of any subagents defined in the frontmatter.
4. **Usage**: How to invoke or use the skill.
5. **Workflow/Steps**: The systematic approach the agent should follow when the skill is active.
6. **Rules & Constraints**: Any critical limitations or formatting rules the agent must adhere to.

## How to Create a Skill
1. Identify the name, purpose, dependencies, and subagents for the skill.
2. Determine if the skill requires any helper scripts. If so, create a `scripts/` directory inside the skill folder (`.agents/skills/<skill-name>/scripts/`).
3. If the skill uses subagents, create a `subagents/` directory (`.agents/skills/<skill-name>/subagents/`) and scaffold a `.md` file for each subagent containing their system prompt (e.g., `researcher.md`).
4. Write the `SKILL.md` file inside `.agents/skills/<skill-name>/` using the `write_to_file` tool.

Example `SKILL.md`:
```yaml
---
name: example-skill
description: An example skill to demonstrate formatting
dependencies:
  - jq
  - curl
subagents:
  - researcher
---
# Example Skill
...
```
