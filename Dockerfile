# =============================================================================
# arch-builder — 每日预构建的 Arch 构建环境镜像
#
# 由 .github/workflows/build-arch-builder-image.yaml 每日维护（GHCR:
# ghcr.io/<owner>/custom_lib_build/arch-builder:latest）。
#
# 目的：CI 构建 job 复用此镜像，避免每次从公共 mirror 全量下载
# base-devel 工具链（~850MB）——既拖慢构建又浪费公共资源，
# 还经常触发 mirror 限速（"Operation too slow"）导致失败。
#
# /var/cache/pacman/pkg 缓存刻意保留在镜像层中：runtime 的增量
# `pacman -Syu` 对未变化的包直接命中缓存，零下载。
# =============================================================================

FROM archlinux:latest

# 1. 初始化 pacman keyring——避免 runtime 升级 archlinux-keyring 时
#    报 "There is no secret key available to sign with"
#    （--init 在已有 keyring 时会交互询问是否重建，非交互构建环境
#     必须删除后重建，保证幂等）
RUN rm -rf /etc/pacman.d/gnupg && pacman-key --init && pacman-key --populate archlinux

# 2. 全量升级 + 安装构建/发布所需依赖（一次性，构建镜像时完成）
#    - base-devel: gcc / binutils / make / pkgconf 等基础编译工具链
#    - clang / llvm / lld / cmake / ninja / ccache: 现代 C/C++ 构建链
#    - rust / cargo / go / nodejs / npm / python: 常见语言工具链
#      （AUR 包构建的高频依赖，预装免去每次下载）
#    - tar / zip / unzip / wget / curl: 源码下载与打包工具
#    - gnupg / jq / pacman-contrib / sudo: 发布与构建流程依赖
RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm --needed \
      base-devel git gnupg jq libglvnd pacman-contrib sudo \
      clang llvm lld cmake ninja ccache \
      rust cargo go nodejs npm python python-pip \
      tar zip unzip wget
