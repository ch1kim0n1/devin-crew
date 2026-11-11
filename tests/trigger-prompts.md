# Trigger check for the skill description

Re-run after any change to the `description:` line in SKILL.md. Give a fresh model a realistic skill list (this skill plus about ten neighbors such as brainstorming, dispatching-parallel-agents, systematic-debugging, code-review, schedule) and ask which single skill it would invoke first for each message below, or NONE.

## Must trigger devin-crew

1. `/devin-crew add dark mode to the settings page`
2. use devin to build the whole export feature, split it across a few agents
3. spin up 4 Devins on this repo and have them refactor the API layer in parallel
4. can you control devin cli for me and have it write the test suite while you plan the rest
5. orchestrate a Devin crew to migrate our CSS to tailwind
6. `/devin-crew`
7. I want you to be the control panel for several Devin agents working on this project
8. get devin to implement these 6 tickets, then check their work when they're done

## Must NOT trigger it

9. what's the difference between Devin and Claude Code?
10. help me install the devin cli and log in
11. dispatch 3 subagents to research these libraries in parallel  (belongs to dispatching-parallel-agents)
12. fix this failing unit test  (systematic-debugging)
13. write a cron schedule for nightly backups
14. review my PR before I merge it  (code-review)
15. explain how git worktrees work
16. how much does Devin cost per month?

## Last result (2026-11-10, fresh sonnet model, 12-skill list)

16/16 as expected. 1-8 routed to devin-crew; 9, 10, 13, 15, 16 NONE; 11 dispatching-parallel-agents; 12 systematic-debugging; 14 engineering:code-review.
