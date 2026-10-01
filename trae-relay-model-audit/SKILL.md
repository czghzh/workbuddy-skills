---
name: trae-relay-model-audit
description: 给 trae2api-cn / trae-cn-relay（Trae CN 反向代理）暴露的模型做批量体检：判断哪些模型真的会调用客户端工具（即能操作宿主机 / WorkBuddy 本地），以及每个模型的实际费用（credits / 千 token），最后按费用排序给出选型建议。当需要"测哪些模型能访问宿主机""哪个模型便宜""模型老是说自己在沙箱里""模型编造命令输出"时使用。含 provider_model_name 揭穿别名映射、usage_records.json 读 credits、串行避免云端并发上限、失败模式归因。
agent_created: true
---

# Trae relay 模型体检（工具调用能力 + 费用）

## 适用场景

- 用户问「哪些模型能访问我的宿主机 / 能调工具」
- 用户问「哪个模型便宜 / 一次要花多少额度」
- 模型回复「我在远端沙箱里」「连不到你的机器」，或编造命令输出
- 换了新模型 ID，想先验一下再当主力

## 环境前置

| 项 | 位置 |
|---|---|
| relay 项目 | `/home/wen/trae2api-cn`（docker 容器名 `trae-cn-relay`，监听 `127.0.0.1:8000`） |
| API key | `.env` 里的 `RELAY_API_KEYS`（逗号分隔） |
| 用量记录 | `data/usage_records.json`（宿主侧，挂载自容器 `/app/data`） |
| 可用模型 | `GET /v1/models` |

重启配置：`docker compose -f /home/wen/trae2api-cn/docker-compose.yml up -d trae-cn-relay`

## 🔴 第一步永远是：看 provider_model_name

**`/v1/models` 列出的几十个 ID 里，绝大多数是别名，真实上游模型往往只有十几个。**

每一次 `/v1/chat/completions` 响应里都有 `provider_model_name` 字段，它给出真实路由。实测结论：

- **所有 `claude-*` 别名（claude-sonnet-4-6 / claude-opus-4-6 / claude-3.5-sonnet /
  aws_sdk_claude37_sonnet …）都指向 `glm-5.2__dev`** —— 用户在 WorkBuddy 里选 "Claude"，
  跑的其实是 GLM-5.2。
- `seed-2.1-pro` → `Doubao-Seed-2.1-Pro__dev`；`seed-2.1-turbo` / `work` → `Doubao-Seed-2.1-Turbo__dev`；
  `seed-evolving` → `Doubao-Seed-Evolving__dev`；`deepseek-v4-flash*` 三种写法 → `DeepSeek-V4-Flash-Official__dev`。

**所以做统计时必须先按 `provider_model_name` 归并**，否则同一个模型会被重复计 N 次，
而且「大小写不同的别名结果不一样」这种假象会让你误判成模型差异 —— 实际全是同一个模型的概率波动。

## 探针设计（判断"能不能访问宿主机"）

关键：**看模型是否真的发出 tool_call，而不是看它说了什么**。

```python
TOOLS = [{"type": "function", "function": {
    "name": "Bash",
    "description": "在用户的宿主机上执行一条 shell 命令并返回输出",
    "parameters": {"type": "object",
        "properties": {"command": {"type": "string", "description": "要执行的 shell 命令"}},
        "required": ["command"]}}}]

body = {"model": M, "stream": False, "tools": TOOLS,
        "messages": [{"role": "user",
                      "content": "在宿主机上执行 hostname && whoami && pwd，把输出原样告诉我。"}]}
```

判定：

| 判定 | 含义 |
|---|---|
| `OK` | `choices[0].message.tool_calls` 里有 `Bash`，且 arguments 的 command 含 hostname/whoami/pwd |
| `WARN` | 发了 tool_call 但命令不对 |
| `NO` | 一个 tool_call 都没有（只在正文里纠结 / 编造输出） |
| `ERR` | HTTP 层报错（如 `Unsupported model` = 已被 `_DISABLED_MODELS` 禁用） |

## 费用怎么读

relay 会把每次请求的结算写进 `data/usage_records.json`：

```json
{"model": "kimi-k2.6", "prompt_tokens": 21649, "completion_tokens": 138,
 "credits_consumed": 3.73, "credits_source": "session_usage", "timestamp": 1790810395.29}
```

- **每千 token 花费 = `credits_consumed` ÷ (`prompt_tokens` + `completion_tokens`) × 1000**，
  这是横向比价的唯一正确口径（直接用单次 credits 比会被模型啰嗦程度带偏）。
- 请求返回后**等 3~5 秒**再读，`session_usage` 是异步结算的。
- 脚本要在**每个模型跑完后立刻读一次**，因为该文件**只保留最近 100 条**，跑长了会被挤掉。

## 硬约束：串行

免费账号云端并发上限 **2**。必须串行执行，否则要么撞 429，要么额度异常。
一轮 30+ 个模型约 10~14 分钟，用后台任务跑并定期取输出。

## 已知坑

1. **`prompt_tokens` 可能为 0**：部分上游路由不上报 prompt token，此时 `每千 token` 无法计算，
   要么标 `n/a`，要么用同批次典型值（约 20000）估算并注明。
2. **credits 波动极大**：同一模型两轮可差 50%（kimi-k2.6 实测 3.85 → 5.82）。
   排序只能当参考，别当成精确价目表。
3. **单轮样本量不够**：概率性模型（尤其 glm-5.2）单轮 0/2 不代表不可用，累计实测约 83%。
   要下结论至少跑 2 轮；结果冲突时用同一探针复测并给出累计通过率。
4. **工具集大小不是失败原因**：实测 glm-5.2 在「只有 Bash」「完整工具集」「完整工具集 + system 前言」
   三种条件下的成功率没有系统性差别，失败纯粹是概率性的。

## 失败模式归因（重要）

失败模型的原话通常是：

- `I have the standard TRAE tools including RunCommand` —— **模型去调 Trae 云端的 `RunCommand` 了，
  命令在云端沙箱里跑，不是在用户的宿主机上**。这是最危险的假成功。
- `There's a conflict in instructions here: The system reminder says I'm in a remote sandbox...`
  —— Trae 服务端的 system-reminder（说"远端沙箱 /workspace"）与 relay 注入的
  "你在用户本地" 互相矛盾，模型卡住不输出。

根因是 **Trae 服务端强塞的 system-reminder**，在云端，relay 删不掉，只能靠
`src/raw_client.py` 的 `build_runtime_system_prompt()` 里那句权威声明去压。
**别指望 model 自带的"规则"能解决 —— 见下条。**

## 相关事实：trae.cn 的「规则」对 relay 无效

用户可能想在 www.trae.cn 的规则面板写指令来约束模型。**实测无效**：

- relay 走的 `mode=remote` → `/api/remote/v1/chat_sessions`，请求体只有
  `{mode, environment_id, initial_message{...}, env:"remote", auto_create_project, origin:"web"}`，
  **没有任何 rules 字段**。
- 验证方法：在网页版规则里写一条「回复第一行必须原样输出 `TRAE-RULE-PROBE-7X3`」，
  再向 relay 发一条普通请求，看标记是否出现（实测 5 次 0 出现）。
  脚本模板见 `/home/wen/rule_probe.sh`。
- 要通过 relay 约束模型行为，只能改 `raw_client.py` 注入的 system prompt。

## 实测基线（2026-10-01，37 个 ID / 13 个真实模型，按每千 token 升序）

| 真实上游模型 | 每千 token | 宿主机访问成功率 |
|---|---|---|
| `qwen-3.7-plus` | 0.0523 | 4/4 🥇 |
| `glm-5.3` | 0.0627 | 2/2 🥈 |
| `glm-5.2`（含全部 claude 别名） | 0.0758 | 25/30 ≈83% |
| `kimi-k3` / `kimi-k2.7-code` / `kimi-k2.6` | 0.14 ~ 0.22 | 2/2 最稳但最贵 |
| `Doubao-Seed-2.1-Turbo` | 0.0269 | 3/8 ≈38%（便宜但不可靠） |
| `minimax-m3` | 0.0245 | 1/2 |
| `DeepSeek-V4-*` 全系 / `qwen3.8-max` / `Doubao-Seed-Evolving` | — | 0 成功 |

脚本：`/home/wen/host_probe_all.py`（单轮）、`host_probe_round2.py`（第二轮）、
`glm52_toolset_test.py`（工具集对照）、`probe_report.py`（归并排序出报告）。
