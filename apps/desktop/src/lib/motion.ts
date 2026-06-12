import type { Variants } from "framer-motion";
import { useReducedMotion } from "framer-motion";

/** 淡入 + 上移：opacity 0→1, y 8→0, duration 0.2, easeOut */
export const fadeInUp: Variants = {
  hidden: { opacity: 0, y: 8 },
  visible: { opacity: 1, y: 0 },
};

/** 淡入：opacity 0→1, duration 0.15 */
export const fadeIn: Variants = {
  hidden: { opacity: 0 },
  visible: { opacity: 1 },
};

/** 从左滑入：opacity 0→1, x -8→0, duration 0.18 */
export const slideInRight: Variants = {
  hidden: { opacity: 0, x: -8 },
  visible: { opacity: 1, x: 0 },
};

/** 交错容器：staggerChildren 0.04 */
export const staggerContainer: Variants = {
  hidden: {},
  visible: {
    transition: { staggerChildren: 0.04 },
  },
};

/** 便捷 re-export，业务层直接使用 */
export { useReducedMotion };
