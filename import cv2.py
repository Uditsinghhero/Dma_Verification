import cv2
import numpy as np
import matplotlib.pyplot as plt
import time

# =========================================
# LOAD IMAGE
# =========================================

img = cv2.imread(
    "C:\\Users\\acer\\OneDrive\\Desktop\\IP_FPGA\\Testing\\glioma\\Te-gl_1.jpg",
    cv2.IMREAD_GRAYSCALE
)

# =========================================
# START TIMER
# =========================================

t0 = time.time()

# =========================================
# GAUSSIAN BLUR
# =========================================

gaussian = cv2.GaussianBlur(
    img,
    (5,5),
    1.2
)

# =========================================
# SOBEL EDGE
# =========================================

sobelx = cv2.Sobel(
    gaussian,
    cv2.CV_64F,
    1,
    0,
    ksize=3
)

sobely = cv2.Sobel(
    gaussian,
    cv2.CV_64F,
    0,
    1,
    ksize=3
)

sobel = cv2.magnitude(
    sobelx,
    sobely
)

sobel = np.uint8(
    np.clip(sobel, 0, 255)
)

# =========================================
# MORPHOLOGY
# =========================================

kernel = np.ones((3,3), np.uint8)

morph = cv2.morphologyEx(
    sobel,
    cv2.MORPH_CLOSE,
    kernel
)

# =========================================
# END TIMER
# =========================================

cpu_time = time.time() - t0

print(f"\nCPU Processing Time: {cpu_time:.6f} sec")

# =========================================
# DISPLAY
# =========================================

fig, ax = plt.subplots(1,3, figsize=(18,5))

ax[0].imshow(img, cmap='gray')
ax[0].set_title("Original MRI")

ax[1].imshow(sobel, cmap='gray')
ax[1].set_title("CPU Sobel")

ax[2].imshow(morph, cmap='gray')
ax[2].set_title("CPU Morphology")

for a in ax:
    a.axis('off')

plt.tight_layout()
plt.show()