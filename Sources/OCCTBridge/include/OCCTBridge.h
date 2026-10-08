// OCCTBridge — a small C ABI over OpenCASCADE so Swift never sees C++.
// All shapes are opaque handles owned by the caller (free with ob_shape_free).
// Functions returning OBShape* return NULL on failure; ob_last_error() explains why.

#ifndef OCCT_BRIDGE_H
#define OCCT_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct OBShape OBShape;

typedef struct {
    double origin[3];
    double xDir[3];
    double normal[3];
} OBPlane;

enum { OB_SEG_LINE = 0, OB_SEG_ARC = 1, OB_SEG_CIRCLE = 2 };

/// A 2D sketch curve in plane coordinates. Arcs run counter-clockwise from `a` to `b` around `c`.
typedef struct {
    int32_t kind;
    double a[2];
    double b[2];
    double c[2];
    double radius;
} OBSegment;

enum { OB_BOOL_FUSE = 0, OB_BOOL_CUT = 1, OB_BOOL_COMMON = 2 };

typedef struct {
    float *positions;      // 3 * vertexCount
    float *normals;        // 3 * vertexCount
    uint32_t *faceIds;     // vertexCount (0-based face index)
    int32_t vertexCount;
    uint32_t *indices;     // indexCount
    int32_t indexCount;
    float *edgePoints;     // 6 * edgeSegmentCount (pairs of 3D points)
    uint32_t *edgeIds;     // edgeSegmentCount (0-based edge index)
    int32_t edgeSegmentCount;
    int32_t faceCount;
    int32_t edgeCount;
} OBMesh;

typedef struct {
    int32_t isPlanar;
    double origin[3];      // point on plane (planar faces)
    double normal[3];      // outward normal (planar faces), else normal at centroid
    double centroid[3];
    double area;
} OBFaceInfo;

typedef struct {
    int32_t kind;          // 0 = line, 1 = circle/arc, 2 = other
    double midpoint[3];
    double start[3];
    double end[3];
    double length;
} OBEdgeInfo;

const char *ob_last_error(void);

void ob_shape_free(OBShape *s);
int32_t ob_shape_is_null(const OBShape *s);
int32_t ob_shape_face_count(const OBShape *s);
int32_t ob_shape_edge_count(const OBShape *s);
int32_t ob_shape_solid_count(const OBShape *s);
OBShape *ob_shape_face(const OBShape *s, int32_t index);
OBShape *ob_shape_solid(const OBShape *s, int32_t index);
double ob_shape_volume(const OBShape *s);
double ob_shape_area(const OBShape *s);
int32_t ob_shape_bbox(const OBShape *s, double outMin[3], double outMax[3]);

/// Splits the plane by all given curves and returns a compound of the enclosed regions (faces).
OBShape *ob_sketch_regions(const OBPlane *plane, const OBSegment *segs, int32_t count);
/// 1 if the 3D point lies inside (or on) the face.
int32_t ob_face_contains(const OBShape *face, const double p[3]);

OBShape *ob_compound(const OBShape *const *shapes, int32_t count);
OBShape *ob_fuse_faces(const OBShape *const *faces, int32_t count);

OBShape *ob_prism(const OBShape *profile, const double dir[3]);
OBShape *ob_translate(const OBShape *s, const double v[3]);
OBShape *ob_revolve(const OBShape *profile, const double axisOrigin[3], const double axisDir[3], double angleRad);
OBShape *ob_boolean(const OBShape *a, const OBShape *b, int32_t op);
OBShape *ob_unify(const OBShape *s);
OBShape *ob_fillet(const OBShape *s, const int32_t *edges, int32_t count, double radius);
OBShape *ob_chamfer(const OBShape *s, const int32_t *edges, int32_t count, double distance);
OBShape *ob_shell(const OBShape *s, const int32_t *faces, int32_t count, double thickness);

int32_t ob_face_info(const OBShape *s, int32_t index, OBFaceInfo *out);
int32_t ob_edge_info(const OBShape *s, int32_t index, OBEdgeInfo *out);

int32_t ob_mesh(const OBShape *s, double linearDeflection, double angularDeflection, OBMesh *out);
void ob_mesh_free(OBMesh *m);

/// Hidden-line projection result. Coordinates are 2D in the projection plane (model units).
enum { OB_LINE_HIDDEN = 1, OB_LINE_OUTLINE = 2, OB_LINE_SMOOTH = 4 };

typedef struct {
    float *points;          // 2 * pointCount (x, y)
    int32_t pointCount;
    int32_t *polyStart;     // polyCount + 1 offsets into points
    uint8_t *polyFlags;     // OB_LINE_* per polyline
    int32_t polyCount;
    double *circles;        // 5 * circleCount: cx, cy, r, startAngle, sweep (full circle: sweep = 2pi)
    uint8_t *circleFlags;   // OB_LINE_* per circle
    int32_t circleCount;
} OBProjection;

/// Exact hidden-line removal. `viewDir` points from the model towards the viewer, `xDir` is the
/// drawing's horizontal axis. Returns 0 on failure (see ob_last_error).
int32_t ob_hlr(const OBShape *s, const double viewDir[3], const double xDir[3], double deflection, OBProjection *out);
void ob_projection_free(OBProjection *p);

int32_t ob_write_stl(const OBShape *s, const char *path, double linearDeflection, int32_t ascii);
int32_t ob_write_step(const OBShape *s, const char *path);
OBShape *ob_read_step(const char *path);

#ifdef __cplusplus
}
#endif

#endif
