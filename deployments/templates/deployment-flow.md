# 部署流程：<在此填写名称，例如 prod 首次上线 / 0002 增加 posts 表>

> 复制本模板到 `deployments/<deployment-name>/plan.md` 后逐项填写。
> 命令示例基于 `dbauto` CLI；`<...>` 为需要替换的占位符。

## 1. 元信息

| 项目 | 值 |
| --- | --- |
| 目标环境 | `<dev / staging / prod>` |
| 数据库 URL | `<sqlite:///path/to/target.db>` |
| 迁移版本范围 | `<0001 .. 0002>` |
| 负责人 / 执行人 | `<name>` |
| 计划执行时间 | `<YYYY-MM-DD HH:MM TZ>` |
| 变更评审 | `<链接或说明>` |

## 2. 前置检查

- [ ] 目标数据库可连接，`dbauto --database-url <URL> status` 可正常输出。
- [ ] 待应用的迁移已合并并通过评审（对照“迁移版本范围”）。
- [ ] `dbauto --database-url <URL> migrate --dry-run` 列出的待执行项与预期一致。
- [ ] 已确认执行账号具备所需权限，磁盘/资源充足。

```bash
dbauto --database-url "<URL>" status
dbauto --database-url "<URL>" migrate --dry-run
```

## 3. 备份

在执行任何变更前，对目标库做可恢复备份，并记录备份位置。

```bash
# SQLite 示例：直接复制数据文件
cp "<path/to/target.db>" "<path/to/target.db>.$(date +%Y%m%d%H%M%S).bak"
```

- 备份位置：`<...>`

## 4. 执行步骤

按顺序执行，逐条确认成功后再进行下一步。

```bash
# 应用全部待执行迁移
dbauto --database-url "<URL>" migrate

# （仅非生产环境需要时）载入种子数据
# dbauto --database-url "<URL>" seed
```

## 5. 验证

```bash
# 确认所有目标迁移均为 applied、0 pending
dbauto --database-url "<URL>" status

# 按业务预期抽查数据
dbauto --database-url "<URL>" query "<SELECT ...>"
```

预期结果：

- [ ] `status` 中目标范围内的迁移全部为 `applied`，无 `pending`、无 `drifted`。
- [ ] 抽查查询返回结果符合预期。

## 6. 回滚方案

若任一环节失败：

1. 停止后续步骤。
2. 使用第 3 节的备份还原目标库：
   ```bash
   cp "<path/to/target.db>.<timestamp>.bak" "<path/to/target.db>"
   ```
3. 记录失败现象与日志，评估修复后重试。

## 7. 执行记录

| 项目 | 值 |
| --- | --- |
| 实际执行时间 | `<...>` |
| 实际执行人 | `<...>` |
| 结果 | `<成功 / 回滚 / 部分完成>` |
| 关键输出 / 备注 | `<粘贴 status、migrate 的关键输出>` |
