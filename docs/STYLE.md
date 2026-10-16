# Writing style

All text in this repository uses Simplified Technical English (STE,
ASD-STE100). This applies to README files, procedures, comments in
playbooks and task names.

## Rules

1. Write one instruction in one sentence.
2. Write procedures in the imperative: "Run the playbook.", "Do not start
   VM 102."
3. Put a condition before the instruction: "If the check fails, stop."
4. Keep a procedural sentence to 20 words or fewer.
5. Keep a descriptive sentence to 25 words or fewer.
6. Use the active voice: "The playbook removes the record.", not "The record
   is removed."
7. Use one word for one thing. If a page says "domain controller", it does not
   also say "DC server" or "AD box".
8. Use simple words: "use", not "utilize"; "start", not "initiate"; "make
   sure", not "ensure".
9. Keep "the" and "a". Do not write in note form.
10. Keep a paragraph to six sentences or fewer, about one topic.
11. Put each step of a procedure in a numbered list, one action for each step.
12. Put a safety note immediately before the step it is about:
    - **WARNING:** a risk of data loss or of an outage.
    - **CAUTION:** a risk of damage to the configuration.
    - **NOTE:** information that helps.
13. Put names of files, commands, variables, hosts and Windows features in
    `code` format.
14. Write what the code does now. History and investigations go in the
    commit messages and the pull requests, not in the README files.

## Template for a role

```markdown
# <role name>

<One sentence: what the role does.>

## What it does

1. <First action.>
2. <Next action.>

## Requirements

- <What must be true before the role runs.>

## Variables

| Variable | Default | Description |
| --- | --- | --- |
| `name` | `value` | <What it controls.> |

## How to use it

<Which playbook applies it, and the command.>

## Safety

**WARNING:** <...>

## Known problems

- <Problem, and what to do.>
```

## Template for a playbook

Each playbook `playbooks/<name>.yml` has a page `playbooks/<name>.md`.

```markdown
# <name>.yml

<One or two sentences: what the playbook does and when to use it.>

## Before you start

- <Prerequisite.>

## Procedure

1. <Step, with the command.>

## What it changes

- <Hosts and settings that change.>

## If it fails

- <Symptom: what to do.>
```
