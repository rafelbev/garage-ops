# Skills for garage-ops

This directory contains focused skills for AI agents (Goose, Opencode) working on the garage-ops repository.

## Available Skills

| Skill         | File               | Description                                  |
| ------------- | ------------------ | -------------------------------------------- |
| Talos Upgrade | `talos-upgrade.md` | Upgrade Talos and Kubernetes versions        |
| Deploy App    | `deploy-app.md`    | Deploy a new application using Flux and Helm |
| Debug Cluster | `debug-cluster.md` | Troubleshoot cluster issues                  |

## How to Use Skills

### With Goose

Skills can be loaded on demand using the `load_skill` function:

```goose
load_skill(name: "talos-upgrade")
```

Or reference them in your instructions:

```goose
Using the talos-upgrade skill, upgrade Talos to version 1.15.0
```

### With Opencode

Include the skill content in your context or system prompt when working on the relevant task.

## Installing Skills

Skills are stored in this repository and are versioned with the rest of the project. No separate installation is required.

### Adding a New Skill

1. Create a new markdown file in this directory
2. Follow the format of existing skills:
    - Title and description
    - Prerequisites
    - Step-by-step procedure
    - Pitfalls to avoid
    - References
3. Add the skill to the table above
4. Commit and push

### Updating a Skill

1. Edit the skill file
2. Update the description if needed
3. Commit and push

## Skill Format

Each skill should include:

- **Title**: Clear, action-oriented title
- **Description**: When to use this skill
- **Prerequisites**: What's needed before starting
- **Procedure**: Step-by-step instructions with commands
- **Pitfalls**: Common mistakes to avoid
- **References**: Links to documentation

## Maintenance

- Review skills after major cluster changes
- Update skills when procedures change
- Remove skills that are no longer relevant
- Keep skills focused on a single task
