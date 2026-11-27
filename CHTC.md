# 用 R 在本课程的 CHTC 环境运行

数据下载、校验、清洗、匹配、模型、绘图、作业逻辑和中间结果打包均使用 **R**。
CHTC 必需的 `.sub`、`.dag` 和两个 Shell 启动/准备脚本保留；当前分析流程不需要运行 Python。
调度方式对应[本学期课件](https://pages.stat.wisc.edu/~jgillett/DSCP/schedule.html)及其
[CHTC 示例](https://pages.stat.wisc.edu/~jgillett/DSCP/CHTC/)。方法说明见 [ANALYSIS.md](ANALYSIS.md)。

## 1. 更新代码

```bash
cd DSCPproject7
git pull --ff-only origin main
```

CSV 仍可用普通 Git 获取。但计算作业不会传输整个仓库、`.git` 或全部 CSV。
每个年度作业在执行节点用 R 下载本年的 ZIP、校验并解压月度 CSV，处理后删除原始输入，
只返回指定中间结果。已经拆好的数据不需要重新拆分。

若尚未克隆且只想在 `learn` 保留代码与清单，可以轻量克隆：

```bash
git clone --filter=blob:none --sparse https://github.com/wyfARTHUR/DSCPproject7.git
cd DSCPproject7
git sparse-checkout set --no-cone '/R/' '/scripts/' '/config/' '/chtc/' '/tests/' \
    '/data/*.json' '/*.md' '/.gitattributes' '/.gitignore'
```

## 2. 一次性构建 R 容器

`learn` 不需要安装 R。R 在作业容器中运行，与课程的 `calling_R_python_torch/R` 示例方式一致。
项目提供了 `chtc/dscp-r.def`，包含 `data.table`、`arrow`、`stringi`、`digest`、`jsonlite`、
`ggplot2` 和用于测试的 `zip` 包，并在构建时检查包加载与 Parquet 读写。

在仓库根目录提交交互构建作业：

```bash
condor_submit -i chtc/build.sub
```

进入计算节点后：

```bash
apptainer build dscp-r.sif chtc/dscp-r.def
apptainer exec --cleanenv dscp-r.sif Rscript /opt/dscp/container_check.R
```

成功后，在退出交互作业**之前**，复制镜像到你们已分配、可写入的 staging 路径。
下列路径是占位符，必须替换：

```bash
cp dscp-r.sif /staging/YOUR_ALLOCATED_PATH/dscp-r-v2.sif
sha256sum /staging/YOUR_ALLOCATED_PATH/dscp-r-v2.sif
exit
```

构建作业关闭了镜像自动返回，所以务必先完成复制。不要在登录节点构建容器。
保存镜像 SHA-256 和包版本输出，同一轮分析不要替换镜像内容。
参见 [CHTC R 指南](https://chtc.cs.wisc.edu/uw-research-computing/r-jobs)和
[Apptainer 构建指南](https://chtc.cs.wisc.edu/uw-research-computing/apptainer-htc/)。

## 3. 填写镜像路径，准备默认提交文件

```bash
cp config/chtc.env.example config/chtc.env
```

用编辑器把 `DSCP_CONTAINER_IMAGE` 改成真实路径，例如：

```bash
DSCP_CONTAINER_IMAGE=file:///staging/YOUR_ALLOCATED_PATH/dscp-r-v2.sif
```

仓库已附默认的 2010–2025 年、32 个拟合分片的提交模板，因此 `learn` 不需要运行 R 或 Python 来生成它们。
日期范围和统计参数在 `config/analysis.json`。若需要改变日期或分片数，先在有 R 的本地电脑/交互计算环境运行：

```bash
Rscript chtc/make_templates.R
```

再把更新的配置和 `chtc/templates/` 同步到 Git。模板与配置不一致时，准备脚本会停止。

这一版取消了人工审核阶段，使用新的运行目录 `run_auto1`，避免与旧代码生成的中间结果混用：

```bash
bash chtc/prepare.sh all chtc_runs/run_auto1
```

这一步只用标准 Shell、`tar` 和 `sha256sum` 打包少量代码、替换镜像路径、建立日志目录，
**不会提交作业**。代码包排除原始 CSV、`.git`、R 安装目录、镜像和历史 Python 工具。

## 4. 先试跑，再提交完整流水线

```bash
cd chtc_runs/run_auto1
condor_submit pilot.sub
condor_q
```

检查 `logs/` 的 `.out`、`.err`、`.log`，确认镜像、下载、CSV 校验和 Parquet 写入成功。
模板里的资源请求是初始建议，需根据试跑结果调整本运行目录 `.sub` 中的
`request_cpus`、`request_memory`、`request_disk`。

然后提交完整流程（年度作业会重新生成试跑年份的结果）：

```bash
condor_submit_dag all.dag
condor_q -dag -nobatch
```

```text
year.sub: queue year from years.txt
                  |
                  v
merge.sub: 跨年自动匹配和作品分片
                  |
                  v
fit.sub: queue shard from shards.txt
                  |
                  v
compare.sub: 比较、敏感性分析和图表
```

匹配后直接拟合，不需要填写或上传人工审核表，也不需要额外的跳过审核参数。
默认分析共有 16 个年度作业、1 个合并作业、32 个拟合作业和 1 个汇总作业。

年度作业返回 `year-YYYY.rds`，不会返回原始 CSV/ZIP。
合并返回 `matching-bundle.rds` 和 `shard-NNNN-input.rds`。
RDS 包以原始字节保存指定文件，并验证每个成员的 SHA-256；不同作业不依赖共享工作目录。
原有的缺失月份补零、全格式月度分母以及代码/配置版本校验继续保留。

## 5. 分阶段运行与可选匹配配置

也可以先运行 `prepare.dag`（年度处理和匹配），完成后再运行 `fit.dag`（拟合和汇总）：

```bash
# 从仓库根目录运行；使用一个尚未存在的运行目录
bash chtc/prepare.sh prepare chtc_runs/run_auto2
cd chtc_runs/run_auto2
condor_submit_dag prepare.dag
# 等待 prepare.dag 成功，再返回仓库根目录
cd ../..
bash chtc/prepare.sh fit chtc_runs/run_auto2
cd chtc_runs/run_auto2
condor_submit_dag fit.dag
```

`config/match_overrides.tsv` 是可选的别名和排除配置，默认无需填写。
需要修改时，使用精确的规范化标题、作者；要合并的键填写相同 `work_id`，
`include` 为 `TRUE` 或 `FALSE`。仅修改此配置时，可以复用年度结果重跑合并：

```bash
# 从仓库根目录运行
bash chtc/prepare.sh merge chtc_runs/run_auto1
cd chtc_runs/run_auto1
condor_submit_dag merge.dag
# 合并成功后，重新 prepare.sh fit 并提交 fit.dag
```

其他统计代码或配置改变时，应使用新的运行目录。旧版运行目录不能直接沿用此次流程。

## 6. 获取结果

最终图表和表格直接返回到 `results/run/results/`，无须手动解压。
资源/包版本记录在 `results/run/metrics/`，作业状态在 `results/run/job_status/`。
`run_summary.json` 的 `analysis_status=complete` 表示计算完成，`matching_method` 记录自动匹配方法。
图注说明采用自动匹配，不声称人工审核通过。

R 堆内存不是进程 RSS，真实 CHTC 用量还应查看 HTCondor `.log` 或 `condor_history JOB_ID -long`。
每个运行目录冻结代码、配置和镜像 URI；运行中不要更新其文件。
失败作业会返回诊断，非零退出会阻止后续 DAG 节点。缺失分片或版本不一致仍会阻止最终汇总。

## 7. 本地 R 测试

```bash
Rscript tests/test_models.R
Rscript tests/test_pipeline.R
Rscript tests/test_chtc.R
```

最后一个测试使用小型模拟数据和独立沙盒，实际运行 R 年度处理、RDS 文件传输、自动匹配后直接拟合和图表。
它会调用短 Shell 准备脚本，但不调用 Python、HTCondor 或 Apptainer，不提交真实作业。
Linux 镜像构建和真实 CHTC 调度仍需按上述步骤试跑。

参考：[文件传输](https://chtc.cs.wisc.edu/uw-research-computing/htc-job-file-transfer/)、
[DAGMan](https://chtc.cs.wisc.edu/uw-research-computing/htc/dagman-workflows/)。
