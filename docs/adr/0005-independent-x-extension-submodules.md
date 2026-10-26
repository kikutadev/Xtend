# ADR 0005：Xtend関連Chrome拡張機能を独立Submoduleで管理

- 状態：Accepted（2026-10-26）

## 背景

Xtend本体と自作X向けChrome拡張機能の作業場所は同じ製品群としてまとめたいが、拡張ごとのGit履歴・Issue・Release・PRは独立させる必要がある。

## 決定

Xtendリポジトリの `extensions/` に、`x-timeline-filter`、`x-ad-hider`、`x-follower-analyzer` をGit Submoduleで配置する。各リポジトリの履歴とremoteを保ち、Xtendは固定されたコミットIDのみ参照する。`x-home-anchor` と `にゃっとランド` はユーザー管理対象外のため移行しない。Reply Analyzerも対象外とする。

## 不採用案

- ソースをXtendに直接コピー：独立したGit管理・レビュー・リリースが難しくなる。
- `.gitignore` で無視した入れ子のGitリポジトリ：clone後に構成を再現する手段が失われる。

## 影響

各SubmoduleとXtendの参照更新は別コミットになる。FF Analyzerは非公開GitHubリポジトリのため、公開Xtendのclone利用者は全Submoduleの取得にアクセス権を要する。開発用Chromeへの読み込みパスは移動後の `.output/chrome-mv3` に変更する。
