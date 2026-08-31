# 数据库部署流程（Database Deployments）

本目录用于**集中生成与存放数据库部署流程**。每一次要把某个目标数据库从当前状态
安全、可复现地推进到目标状态的完整步骤，都在这里以独立的“部署流程”形式记录和归档。

它与仓库其他部分的关系：

- `migrations/` —— 版本化的 schema 变更（`*.sql`），是部署流程要应用的“变更内容”。
- `seeds/` —— 开发/测试用的种子数据（`*.sql`）。
- `src/dbauto/` —— 执行迁移与种子的 `dbauto` CLI（`migrate` / `seed` / `status` / `query`）。
- `deployments/` —— **本目录**，描述“在某个环境、某个时间点，按什么顺序、做哪些检查”来落地这些变更。

> 简单说：`migrations/` 定义“改什么”，`deployments/` 定义“怎么、在哪、何时安全地改”。

## 目录结构

```
deployments/
├── README.md                     # 本说明
├── templates/
│   └── deployment-flow.md        # 新建部署流程时复制的模板
└── <deployment-name>/            # 每个部署流程一个目录（后续按需生成）
    ├── plan.md                   # 该次部署的流程说明（由模板生成）
    └── ...                       # 可选：环境配置、校验脚本、导出的日志等
```

## 命名约定

每个部署流程放在独立子目录中，推荐命名：

- 按环境 + 日期：`prod-20260901/`、`staging-20260901/`
- 或按发布序号：`0001_initial-schema/`、`0002_add-posts/`

目录名使用小写，单词用连字符 `-`，序号用零填充，保证按字典序排列即为时间/发布顺序。

## 一个“部署流程”应包含什么

参见 `templates/deployment-flow.md`。核心环节：

1. **元信息**：目标环境、数据库 URL、负责人、计划时间、关联的迁移版本范围。
2. **前置检查**：确认当前 `dbauto status`、连接可用、磁盘/权限、变更评审已通过。
3. **备份**：执行前对目标库做可恢复的备份。
4. **执行步骤**：按顺序运行的命令（通常是 `dbauto migrate`，必要时 `dbauto seed`）。
5. **验证**：用 `dbauto status` 与 `dbauto query` 核对结果符合预期。
6. **回滚方案**：失败时如何恢复（还原备份 / 反向变更）。
7. **记录**：实际执行时间、执行人、输出/结论。

## 如何新建一个部署流程

```bash
# 1) 从模板复制到一个新的流程目录
mkdir -p deployments/prod-20260901
cp deployments/templates/deployment-flow.md deployments/prod-20260901/plan.md

# 2) 填写 plan.md 的各章节，并针对目标库预演（dry-run）
dbauto --database-url "sqlite:///path/to/target.db" migrate --dry-run

# 3) 评审通过后按 plan.md 执行，并把关键输出回填到“记录”一节
```
