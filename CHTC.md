# 在本课程的 CHTC 环境运行

这套入口对应课程的 **HTCondor**，使用 `condor_submit`、`queue ... from ...` 和
`condor_submit_dag`，不使用 `sbatch`。
参考：[本学期课程表](https://pages.stat.wisc.edu/~jgillett/DSCP/schedule.html)、
[课程 CHTC 示例](https://pages.stat.wisc.edu/~jgillett/DSCP/CHTC/)。
R 方法、人工匹配规则和结果定义见 [ANALYSIS.md](ANALYSIS.md)。

## 1. 更新代码

登录 `learn.chtc.wisc.edu`，进入已经克隆的仓库：

```bash
cd DSCPproject7
git pull --ff-only origin main
```

CSV 仍直接保存在 Git 中，可以普通 `pull`。但本工作流**不会把整个仓库、`.git` 或全部 CSV
传给每个计算节点**。年度作业会在执行节点下载本年 ZIP，校验并解压月度 CSV；处理后删除输入，
只返回 Parquet 中间结果和诊断信息。这样也避免在每个作业中重复克隆大型仓库。

如果你还没在 `learn` 克隆，且只想保留代码和小型清单，可用这个可选的轻量克隆：

```bash
git clone --filter=blob:none --sparse https://github.com/wyfARTHUR/DSCPproject7.git
cd DSCPproject7
git sparse-checkout set --no-cone '/R/' '/scripts/' '/config/' '/chtc/' '/tests/' \
    '/data/*.json' '/*.md' '/.gitattributes' '/.gitignore'
```

后续仍可用 `git pull` 更新选中的路径。普通全量克隆也能运行；只是会额外保存约 11.36 GB 的 CSV。

## 2. 一次性准备 R 容器

CHTC 节点不能假设预装了 R。课程的 R 示例也是通过 `.sif` 容器提供 R。
本项目还需要 `data.table`、`arrow`、`stringi`、`digest`、`jsonlite` 和 `ggplot2`；
**不要直接假定课程的 tidyverse/FITSio 容器包含这些包**。

仓库提供 `chtc/dscp-r.def` 和交互构建作业。它从 `rocker/r2u:24.04` 安装 R 二进制包，
并在构建时检查包加载、Python 和 Parquet 读写。参见
[CHTC R 指南](https://chtc.cs.wisc.edu/uw-research-computing/r-jobs) 和
[容器构建指南](https://chtc.cs.wisc.edu/uw-research-computing/apptainer-htc/)。

在**仓库根目录**提交交互构建作业：

```bash
condor_submit -i chtc/build.sub
```

进入计算节点后运行：

```bash
apptainer build dscp-r.sif chtc/dscp-r.def
apptainer exec --cleanenv dscp-r.sif Rscript /opt/dscp/container_check.R
```

成功后，**在退出交互作业前**将镜像复制到你们已经获分配、能够写入的 `/staging` 路径。
以下是占位符，必须换成真实路径：

```bash
cp dscp-r.sif /staging/YOUR_ALLOCATED_PATH/dscp-r-v1.sif
sha256sum /staging/YOUR_ALLOCATED_PATH/dscp-r-v1.sif
exit
```

构建提交文件关闭了大文件自动返回，所以不会把新镜像复制回 `learn`；请务必先完成上述复制。
不要在登录节点运行 `apptainer build`。镜像构建成功后保存它的 SHA-256 和包版本输出，
同一轮分析不要替换镜像内容。

本地测试没有构建 Linux 镜像，也没有登录 CHTC。必须先在你们的实际环境完成容器检查和单作业试跑。

## 3. 配置资源与生成提交文件

```bash
cp config/chtc.example.json config/chtc.json
```

编辑 `config/chtc.json`，把 `container_image` 改成真实的镜像 URI，例如：

```json
"container_image": "file:///staging/YOUR_ALLOCATED_PATH/dscp-r-v1.sif"
```

`file:///staging/` 对应的作业配置了 `HasCHTCStaging` 要求。各阶段的 CPU、内存和磁盘请求可以修改；
示例值是初始请求，**不是 CHTC 上的实测资源需求**。R/Arrow 线程数会遵守每个作业申请的 CPU 数。

分析日期、分片数量和统计参数在 `config/analysis.json`，格式映射在 `config/format_map.tsv`。
默认分析 2010 年起的数据、排除 2024 年 5–6 月，并生成 32 个拟合分片。

生成第一阶段文件：

```bash
python3 chtc/workflow.py prepare --run-dir chtc_runs/run1
```

这个命令只生成小型代码包、作业参数表、`.sub` 和 `.dag`，**不会提交任何作业**，也不需要登录节点有 R。
`code.tar.gz` 不包含原始 CSV、`.git`、R 安装目录或 `.sif`。

## 4. 先试跑一个年度作业，再运行准备阶段

```bash
cd chtc_runs/run1
condor_submit pilot.sub
condor_q
```

检查 `logs/` 下的 `.out`、`.err`、`.log`，确认容器、GitHub 下载、CSV 校验和 Parquet 写入都成功。
试跑成功后再提交完整准备阶段：

```bash
condor_submit_dag prepare.dag
condor_q -dag -nobatch
```

`prepare.dag` 的结构为：

```text
year.sub: queue year from years.txt   (2010–2025，各年独立)
                    |
                    v
merge.sub: 合并跨年作品、生成拟合分片和人工审核表
```

依赖要求前一批全部成功，合并才会启动。年度作业只返回 `year-YYYY.tar.gz`，不返回下载的 CSV/ZIP。
合并作业返回：

- `match_review.tsv`：需要人工填写的审核表。
- `match_candidates.tsv`：审核样本的规范化标题、作者、格式和原始示例。
- `review-bundle.tar.gz`：完整匹配元数据、分母和准备阶段诊断。
- `shard-NNNN-input.tar.gz`：每个拟合任务需要的完整跨年时间序列。

这些文件都在 `chtc_runs/run1/`，不是共享的计算节点工作目录。作业之间通过显式文件传输衔接。

## 5. 人工审核与别名修正

编辑 `chtc_runs/run1/match_review.tsv`，只填写：

- `decision`：`accept` 或 `reject`。
- `reviewer`：实际审核的组员姓名。
- `notes`：判断依据。

默认审核最多 200 个自动匹配作品，以及所有人工别名合并的作品。这是抽样审核，
不表示每本书均已人工核验。`reject` 排除该作品的全部格式，但不会改变该格式全体书籍的月度分母。
不要删除审核行、改作品 ID 或改 `review_signature`。

需要合并不同的规范化标题/作者，或排除错误记录时，在仓库根目录编辑
`config/match_overrides.tsv`。从 `match_candidates.tsv` 复制精确的 `title_norm` 和 `creator_norm`；
要合并的键使用相同的稳定 `work_id`，例如 `manual_book_001`。`include` 为 `TRUE` 或 `FALSE`。
更多标题可以在有 R 的本地/交互计算环境用 `scripts/find_work.R` 查询完整目录。

修改别名后，只需重建合并阶段，再审核、再拟合：

```bash
# 从仓库根目录运行
python3 chtc/workflow.py merge --run-dir chtc_runs/run1
cd chtc_runs/run1
condor_submit_dag merge.dag
```

不会重新下载所有原始数据或重跑年度任务。已审核且作品成员未改变的决定会保留；
成员变化时需要重新审核。

## 6. 提交拟合与最终比较

审核完成后，从仓库根目录运行：

```bash
python3 chtc/workflow.py fit --run-dir chtc_runs/run1
cd chtc_runs/run1
condor_submit_dag fit.dag
```

审核未完成、审核 ID 不一致或缺少分片时，生成器会停止。拟合任务还会再次在 R 中核验审核和版本。

```text
fit.sub: queue shard from shards.txt  (默认 32 个任务)
                    |
                    v
compare.sub: 固定效应比较、敏感性分析和图表
```

最终返回 `results.tar.gz`：

```bash
mkdir -p results
tar -xzf results.tar.gz -C results
```

图表和统计表在 `results/run/results/`；任务时间、R 堆内存和 R/package session 信息在
`results/run/metrics/`，各作业状态在 `results/run/job_status/`。HTCondor 的实际内存/磁盘用量还应查看
相应 `.log` 或 `condor_history JOB_ID -long`；R 堆内存不是进程 RSS。

## 7. 探索模式和失败恢复

仅用于检查流程、明确接受未审核匹配的探索版本时，用新的运行目录：

```bash
python3 chtc/workflow.py all --run-dir chtc_runs/exploratory1 --allow-unreviewed
cd chtc_runs/exploratory1
condor_submit_dag all.dag
```

探索输出会标记 `PRELIMINARY_UNREVIEWED`，程序不会伪造审核姓名或自动填写 `accept`。
正式比较仍应完成人工审核，再生成并提交 `fit.dag`。

每个运行目录冻结代码、分析配置和容器 URI。修改统计代码、分析配置或数据清单后应使用新目录；
只有别名表可以用 `merge` 在同一目录重建。不要在 DAG 运行中重新生成它的提交文件。
改变审核决定后必须重跑所有拟合分片。

失败时查看 `.err` 和 `.log`，不要把仍在运行/失败的作业当成成功结果。作业失败也会返回指定的诊断包，
非零退出会阻止后续 DAG 节点；修复问题后可按照 DAGMan 的 rescue 机制恢复。
容器构建、实际调度和真实资源用量需要在 CHTC 试跑，当前本地测试没有代替这些步骤。

参考：[CHTC 文件传输](https://chtc.cs.wisc.edu/uw-research-computing/htc-job-file-transfer/)、
[CHTC staging](https://chtc.cs.wisc.edu/uw-research-computing/file-avail-largedata/)、
[CHTC DAGMan](https://chtc.cs.wisc.edu/uw-research-computing/htc/dagman-workflows/)。
