import 'package:flutter/material.dart';

import '../core/theme.dart';
import 'fnos_image.dart';

/// 分类页统一的方形缩略卡片。
///
/// 人物 / 地点 / 视频 / 图片 四个分类**共用同一个组件与同一套栅格参数**
/// （3 列、正方形、间距 4），从而保证四处卡片尺寸完全一致 ——
/// 之前人物是 3 列「正方形头像 + 下方文字区」，地点是 2 列 0.86 比例，
/// 视频/图片又是另一种，切换分类时卡片大小明显不一致。
///
/// 文字（人物名 / 城市名）改为**叠在图片底部**的渐变蒙层上，
/// 这样单元格可以固定为正方形，不再被文字区撑高。
class SquareThumbTile extends StatelessWidget {
  /// 图片地址（可为空 → 显示占位图标）
  final String imagePath;

  /// 图片参数（人物换封面时用它击穿缓存）
  final Map<String, dynamic>? params;

  /// 底部叠加的文字（人物名 / 城市名）。为空时不画蒙层。
  final String? title;

  /// 是否视频（右下角画播放角标）
  final bool isVideo;

  /// 是实况照片（左下角画实况角标）
  final bool isLive;

  /// 无图时的占位图标
  final IconData? placeholderIcon;

  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const SquareThumbTile({
    super.key,
    required this.imagePath,
    this.params,
    this.title,
    this.isVideo = false,
    this.isLive = false,
    this.placeholderIcon,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(FnosRadius.thumb);
    final hasTitle = title != null && title!.trim().isNotEmpty;

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: ClipRRect(
        borderRadius: radius,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (imagePath.isEmpty)
              Container(
                color: FnosColors.field,
                child: Center(
                  child: Icon(placeholderIcon ?? Icons.image_not_supported,
                      color: FnosColors.textSub, size: 26),
                ),
              )
            else
              FnosImage(
                path: imagePath,
                params: params,
                fit: BoxFit.cover,
                placeholder: Container(
                  color: FnosColors.field,
                  child: Center(
                    child: Icon(placeholderIcon ?? Icons.image_outlined,
                        color: FnosColors.textSub, size: 24),
                  ),
                ),
              ),
            // 文字蒙层：只在有标题时出现，保证无标题的卡片画面干净
            if (hasTitle)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(7, 14, 7, 5),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Color(0xCC000000)],
                    ),
                  ),
                  child: Text(
                    title!,
                    // 系统字体放大到 2.0 时单行 12*2*1.2≈29px 会把文字顶出
                    // 渐变蒙层、直接压在照片上。允许两行 + 把缩放夹在
                    // 0.8..1.5（卡片很小，再大也没有意义且必然溢出）。
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textScaler: MediaQuery.textScalerOf(context)
                        .clamp(minScaleFactor: 0.8, maxScaleFactor: 1.5),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      height: 1.2,
                    ),
                  ),
                ),
              ),
            if (isVideo)
              const Positioned(
                right: 5,
                top: 5,
                child: Icon(Icons.play_circle_fill,
                    color: Colors.white,
                    size: 18,
                    shadows: [Shadow(blurRadius: 4, color: Colors.black54)]),
              ),
            if (isLive && !isVideo)
              const Positioned(
                left: 5,
                top: 5,
                child: Icon(Icons.motion_photos_on,
                    color: Colors.white,
                    size: 15,
                    shadows: [Shadow(blurRadius: 4, color: Colors.black54)]),
              ),
          ],
        ),
      ),
    );
  }
}

/// 分类页统一栅格。
///
/// 四个分类全部用这一个 delegate，任何一处改参数即全局生效 ——
/// 避免「改了一个页面、其余三个还是老尺寸」。
class CategoryGridDelegate extends SliverGridDelegateWithFixedCrossAxisCount {
  const CategoryGridDelegate()
      : super(crossAxisCount: 3, mainAxisSpacing: 4, crossAxisSpacing: 4);
}

/// 分类网格的外边距（与 delegate 的间距配套）
const EdgeInsets kCategoryGridPadding = EdgeInsets.all(4);

/// 根据可用宽度动态计算网格列数。
///
/// 目标：让卡片在任何屏幕方向下保持**接近的物理尺寸**，而不是固定列数
/// —— 否则横屏时同一批卡片会被撑得巨大（用户反馈「横屏只放得下 3 个」）。
///
/// [portrait] 是竖屏下的列数基准；横屏时按目标卡宽（约 130px）折算，
/// 并限制在 `[portrait, max]` 范围内，避免极端窄屏下出现 1 列或 20 列。
int gridColumns(BuildContext context,
    {int portrait = 3, int max = 8, double targetCell = 130}) {
  final w = MediaQuery.of(context).size.width;
  final landscape =
      MediaQuery.of(context).orientation == Orientation.landscape;
  if (!landscape) return portrait;
  final cols = (w / targetCell).round();
  return cols.clamp(portrait, max);
}

/// 分类网格的统一 delegate：按屏幕宽度决定列数，始终正方形。
///
/// 与 [CategoryGridDelegate] 的区别：这个会**随屏幕宽度自适应列数**，
/// 用于分类页 / 相册 / 图库等所有正方形网格。
class AdaptiveCategoryGrid extends SliverGridDelegateWithFixedCrossAxisCount {
  AdaptiveCategoryGrid(BuildContext context)
      : super(
          crossAxisCount: gridColumns(context),
          mainAxisSpacing: 4,
          crossAxisSpacing: 4,
        );
}
