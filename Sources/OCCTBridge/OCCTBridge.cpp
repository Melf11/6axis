// Implementation of the OCCTBridge C ABI. Keep this file free of app logic:
// it only translates between plain C data and OpenCASCADE topology.

#include "OCCTBridge.h"

#include <BRepAdaptor_Curve.hxx>
#include <BRepAdaptor_Surface.hxx>
#include <BRepAlgoAPI_Common.hxx>
#include <BRepAlgoAPI_Cut.hxx>
#include <BRepAlgoAPI_Fuse.hxx>
#include <BRepAlgoAPI_Splitter.hxx>
#include <BRepBndLib.hxx>
#include <BRepBuilderAPI_MakeEdge.hxx>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRepBuilderAPI_Transform.hxx>
#include <BRepClass_FaceClassifier.hxx>
#include <BRepFilletAPI_MakeChamfer.hxx>
#include <BRepFilletAPI_MakeFillet.hxx>
#include <BRepGProp.hxx>
#include <BRepLib_ToolTriangulatedShape.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRepOffsetAPI_MakeThickSolid.hxx>
#include <BRepPrimAPI_MakeBox.hxx>
#include <BRepPrimAPI_MakePrism.hxx>
#include <BRepPrimAPI_MakeRevol.hxx>
#include <BRep_Builder.hxx>
#include <BRep_Tool.hxx>
#include <Bnd_Box.hxx>
#include <GCPnts_AbscissaPoint.hxx>
#include <GCPnts_TangentialDeflection.hxx>
#include <GProp_GProps.hxx>
#include <HLRAlgo_Projector.hxx>
#include <HLRBRep_Algo.hxx>
#include <HLRBRep_HLRToShape.hxx>
#include <IFSelect_ReturnStatus.hxx>
#include <Poly_Triangulation.hxx>
#include <STEPControl_Reader.hxx>
#include <STEPControl_Writer.hxx>
#include <ShapeUpgrade_UnifySameDomain.hxx>
#include <Standard_Failure.hxx>
#include <StlAPI_Writer.hxx>
#include <TopExp.hxx>
#include <TopExp_Explorer.hxx>
#include <TopTools_IndexedMapOfShape.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Compound.hxx>
#include <gp_Ax3.hxx>
#include <gp_Circ.hxx>
#include <gp_Pln.hxx>

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

struct OBShape {
    TopoDS_Shape shape;
    TopTools_IndexedMapOfShape faces;
    TopTools_IndexedMapOfShape edges;
    TopTools_IndexedMapOfShape solids;

    explicit OBShape(const TopoDS_Shape &s) : shape(s) {
        if (!s.IsNull()) {
            TopExp::MapShapes(s, TopAbs_FACE, faces);
            TopExp::MapShapes(s, TopAbs_EDGE, edges);
            TopExp::MapShapes(s, TopAbs_SOLID, solids);
        }
    }
};

namespace {

thread_local std::string g_error;

void setError(const std::string &msg) { g_error = msg; }

OBShape *wrap(const TopoDS_Shape &s, const char *whatIfNull) {
    if (s.IsNull()) {
        setError(whatIfNull);
        return nullptr;
    }
    return new OBShape(s);
}

template <typename F> OBShape *guarded(const char *op, F &&body) {
    try {
        return body();
    } catch (const Standard_Failure &e) {
        setError(std::string(op) + ": " + (e.GetMessageString() ? e.GetMessageString() : "OpenCASCADE-Fehler"));
    } catch (const std::exception &e) {
        setError(std::string(op) + ": " + e.what());
    } catch (...) {
        setError(std::string(op) + ": unbekannter Fehler");
    }
    return nullptr;
}

gp_Pnt toPnt(const double p[3]) { return gp_Pnt(p[0], p[1], p[2]); }

gp_Ax3 planeAxes(const OBPlane *pl) {
    return gp_Ax3(toPnt(pl->origin), gp_Dir(pl->normal[0], pl->normal[1], pl->normal[2]),
                  gp_Dir(pl->xDir[0], pl->xDir[1], pl->xDir[2]));
}

gp_Pnt planePoint(const gp_Ax3 &ax, const double uv[2]) {
    gp_XYZ p = ax.Location().XYZ() + ax.XDirection().XYZ() * uv[0] + ax.YDirection().XYZ() * uv[1];
    return gp_Pnt(p);
}

TopoDS_Shape unify(const TopoDS_Shape &s) {
    try {
        ShapeUpgrade_UnifySameDomain u(s, Standard_True, Standard_True, Standard_False);
        u.Build();
        if (!u.Shape().IsNull()) return u.Shape();
    } catch (...) {
    }
    return s;
}

} // namespace

extern "C" {

const char *ob_last_error(void) { return g_error.c_str(); }

void ob_shape_free(OBShape *s) { delete s; }

int32_t ob_shape_is_null(const OBShape *s) { return (!s || s->shape.IsNull()) ? 1 : 0; }
int32_t ob_shape_face_count(const OBShape *s) { return s ? s->faces.Extent() : 0; }
int32_t ob_shape_edge_count(const OBShape *s) { return s ? s->edges.Extent() : 0; }
int32_t ob_shape_solid_count(const OBShape *s) { return s ? s->solids.Extent() : 0; }

OBShape *ob_shape_face(const OBShape *s, int32_t index) {
    if (!s || index < 0 || index >= s->faces.Extent()) {
        setError("Fläche existiert nicht");
        return nullptr;
    }
    return new OBShape(s->faces(index + 1));
}

OBShape *ob_shape_solid(const OBShape *s, int32_t index) {
    if (!s || index < 0 || index >= s->solids.Extent()) {
        setError("Körper existiert nicht");
        return nullptr;
    }
    return new OBShape(s->solids(index + 1));
}

double ob_shape_volume(const OBShape *s) {
    if (!s || s->shape.IsNull()) return 0;
    GProp_GProps p;
    BRepGProp::VolumeProperties(s->shape, p);
    return p.Mass();
}

double ob_shape_area(const OBShape *s) {
    if (!s || s->shape.IsNull()) return 0;
    GProp_GProps p;
    BRepGProp::SurfaceProperties(s->shape, p);
    return p.Mass();
}

int32_t ob_shape_bbox(const OBShape *s, double outMin[3], double outMax[3]) {
    if (!s || s->shape.IsNull()) return 0;
    Bnd_Box box;
    BRepBndLib::Add(s->shape, box);
    if (box.IsVoid()) return 0;
    box.Get(outMin[0], outMin[1], outMin[2], outMax[0], outMax[1], outMax[2]);
    return 1;
}

OBShape *ob_sketch_regions(const OBPlane *plane, const OBSegment *segs, int32_t count) {
    return guarded("Profilerkennung", [&]() -> OBShape * {
        gp_Ax3 ax = planeAxes(plane);
        TopTools_ListOfShape tools;
        double umin = 1e300, umax = -1e300, vmin = 1e300, vmax = -1e300;
        auto grow = [&](double u, double v, double r) {
            umin = std::min(umin, u - r); umax = std::max(umax, u + r);
            vmin = std::min(vmin, v - r); vmax = std::max(vmax, v + r);
        };

        for (int32_t i = 0; i < count; i++) {
            const OBSegment &sg = segs[i];
            try {
                if (sg.kind == OB_SEG_LINE) {
                    gp_Pnt a = planePoint(ax, sg.a), b = planePoint(ax, sg.b);
                    if (a.Distance(b) < 1e-7) continue;
                    tools.Append(BRepBuilderAPI_MakeEdge(a, b).Edge());
                    grow(sg.a[0], sg.a[1], 0);
                    grow(sg.b[0], sg.b[1], 0);
                } else if (sg.radius > 1e-7) {
                    gp_Ax2 cax(planePoint(ax, sg.c), ax.Direction(), ax.XDirection());
                    gp_Circ circ(cax, sg.radius);
                    if (sg.kind == OB_SEG_CIRCLE) {
                        tools.Append(BRepBuilderAPI_MakeEdge(circ).Edge());
                    } else {
                        gp_Pnt a = planePoint(ax, sg.a), b = planePoint(ax, sg.b);
                        if (a.Distance(b) < 1e-7) continue;
                        tools.Append(BRepBuilderAPI_MakeEdge(circ, a, b).Edge());
                    }
                    grow(sg.c[0], sg.c[1], sg.radius);
                }
            } catch (...) {
                // Skip degenerate curves; the remaining ones may still form profiles.
            }
        }
        if (tools.IsEmpty()) return new OBShape(TopoDS_Compound());

        double margin = std::max(umax - umin, vmax - vmin) * 0.1 + 1.0;
        umin -= margin; umax += margin; vmin -= margin; vmax += margin;
        TopoDS_Face base = BRepBuilderAPI_MakeFace(gp_Pln(ax), umin, umax, vmin, vmax).Face();

        BRepAlgoAPI_Splitter splitter;
        TopTools_ListOfShape args;
        args.Append(base);
        splitter.SetArguments(args);
        splitter.SetTools(tools);
        splitter.SetFuzzyValue(1e-6);
        splitter.Build();
        if (splitter.HasErrors()) {
            setError("Profilerkennung fehlgeschlagen");
            return nullptr;
        }

        BRep_Builder builder;
        TopoDS_Compound result;
        builder.MakeCompound(result);
        double tol = margin * 1e-3;
        gp_XYZ o = ax.Location().XYZ(), xd = ax.XDirection().XYZ(), yd = ax.YDirection().XYZ();
        for (TopExp_Explorer ex(splitter.Shape(), TopAbs_FACE); ex.More(); ex.Next()) {
            bool outer = false;
            for (TopExp_Explorer vx(ex.Current(), TopAbs_VERTEX); vx.More() && !outer; vx.Next()) {
                gp_XYZ p = BRep_Tool::Pnt(TopoDS::Vertex(vx.Current())).XYZ() - o;
                double u = p.Dot(xd), v = p.Dot(yd);
                outer = std::abs(u - umin) < tol || std::abs(u - umax) < tol || std::abs(v - vmin) < tol ||
                        std::abs(v - vmax) < tol;
            }
            if (!outer) builder.Add(result, ex.Current());
        }
        return new OBShape(result);
    });
}

int32_t ob_face_contains(const OBShape *face, const double p[3]) {
    if (!face || face->shape.IsNull() || face->shape.ShapeType() != TopAbs_FACE) return 0;
    try {
        BRepClass_FaceClassifier cls(TopoDS::Face(face->shape), toPnt(p), 1e-6);
        TopAbs_State st = cls.State();
        return (st == TopAbs_IN || st == TopAbs_ON) ? 1 : 0;
    } catch (...) {
        return 0;
    }
}

OBShape *ob_compound(const OBShape *const *shapes, int32_t count) {
    BRep_Builder b;
    TopoDS_Compound c;
    b.MakeCompound(c);
    for (int32_t i = 0; i < count; i++)
        if (shapes[i] && !shapes[i]->shape.IsNull()) b.Add(c, shapes[i]->shape);
    return new OBShape(c);
}

OBShape *ob_fuse_faces(const OBShape *const *faces, int32_t count) {
    return guarded("Profile vereinen", [&]() -> OBShape * {
        if (count <= 0) {
            setError("Kein Profil");
            return nullptr;
        }
        TopoDS_Shape acc = faces[0]->shape;
        for (int32_t i = 1; i < count; i++) {
            BRepAlgoAPI_Fuse f(acc, faces[i]->shape);
            if (f.HasErrors()) {
                setError("Profile konnten nicht vereint werden");
                return nullptr;
            }
            acc = f.Shape();
        }
        return wrap(unify(acc), "Profile vereinen ergab nichts");
    });
}

OBShape *ob_prism(const OBShape *profile, const double dir[3]) {
    return guarded("Extrusion", [&]() -> OBShape * {
        gp_Vec v(dir[0], dir[1], dir[2]);
        if (v.Magnitude() < 1e-9) {
            setError("Extrusion: Abstand ist null");
            return nullptr;
        }
        BRepPrimAPI_MakePrism mk(profile->shape, v);
        mk.Build();
        if (!mk.IsDone()) {
            setError("Extrusion fehlgeschlagen");
            return nullptr;
        }
        return wrap(mk.Shape(), "Extrusion ergab nichts");
    });
}

OBShape *ob_translate(const OBShape *s, const double v[3]) {
    return guarded("Verschieben", [&]() -> OBShape * {
        gp_Trsf t;
        t.SetTranslation(gp_Vec(v[0], v[1], v[2]));
        return wrap(BRepBuilderAPI_Transform(s->shape, t, Standard_True).Shape(), "Verschieben ergab nichts");
    });
}

OBShape *ob_transform(const OBShape *s, const double m[12]) {
    return guarded("Transformieren", [&]() -> OBShape * {
        gp_Trsf t;
        t.SetValues(m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9], m[10], m[11]);
        return wrap(BRepBuilderAPI_Transform(s->shape, t, Standard_True).Shape(), "Transformieren ergab nichts");
    });
}

OBShape *ob_revolve(const OBShape *profile, const double axisOrigin[3], const double axisDir[3], double angleRad) {
    return guarded("Drehung", [&]() -> OBShape * {
        gp_Ax1 axis(toPnt(axisOrigin), gp_Dir(axisDir[0], axisDir[1], axisDir[2]));
        BRepPrimAPI_MakeRevol mk(profile->shape, axis, angleRad);
        mk.Build();
        if (!mk.IsDone()) {
            setError("Drehung fehlgeschlagen (schneidet das Profil die Achse?)");
            return nullptr;
        }
        return wrap(mk.Shape(), "Drehung ergab nichts");
    });
}

OBShape *ob_boolean(const OBShape *a, const OBShape *b, int32_t op) {
    return guarded("Boolesche Operation", [&]() -> OBShape * {
        TopoDS_Shape r;
        bool failed = false;
        if (op == OB_BOOL_FUSE) {
            BRepAlgoAPI_Fuse f(a->shape, b->shape);
            failed = f.HasErrors();
            r = f.Shape();
        } else if (op == OB_BOOL_CUT) {
            BRepAlgoAPI_Cut f(a->shape, b->shape);
            failed = f.HasErrors();
            r = f.Shape();
        } else {
            BRepAlgoAPI_Common f(a->shape, b->shape);
            failed = f.HasErrors();
            r = f.Shape();
        }
        if (failed) {
            setError("Boolesche Operation fehlgeschlagen");
            return nullptr;
        }
        return wrap(unify(r), "Boolesche Operation ergab nichts");
    });
}

OBShape *ob_fuse_all(const OBShape *const *shapes, int32_t count) {
    return guarded("Vereinigen", [&]() -> OBShape * {
        if (count <= 0) {
            setError("Keine Geometrie");
            return nullptr;
        }
        if (count == 1) return wrap(shapes[0]->shape, "Vereinigen ergab nichts");
        TopTools_ListOfShape args, tools;
        args.Append(shapes[0]->shape);
        for (int32_t i = 1; i < count; i++) tools.Append(shapes[i]->shape);
        BRepAlgoAPI_Fuse f;
        f.SetArguments(args);
        f.SetTools(tools);
        f.SetRunParallel(Standard_True);
        f.Build();
        if (f.HasErrors()) {
            setError("Vereinigen fehlgeschlagen");
            return nullptr;
        }
        return wrap(unify(f.Shape()), "Vereinigen ergab nichts");
    });
}

OBShape *ob_unify(const OBShape *s) {
    return guarded("Vereinfachen", [&]() -> OBShape * { return wrap(unify(s->shape), "Vereinfachen ergab nichts"); });
}

OBShape *ob_fillet(const OBShape *s, const int32_t *edges, int32_t count, double radius) {
    return guarded("Abrundung", [&]() -> OBShape * {
        if (radius <= 0) {
            setError("Radius muss größer als 0 sein");
            return nullptr;
        }
        BRepFilletAPI_MakeFillet mk(s->shape);
        for (int32_t i = 0; i < count; i++) {
            if (edges[i] < 0 || edges[i] >= s->edges.Extent()) continue;
            mk.Add(radius, TopoDS::Edge(s->edges(edges[i] + 1)));
        }
        if (mk.NbContours() == 0) {
            setError("Keine Kanten ausgewählt");
            return nullptr;
        }
        mk.Build();
        if (!mk.IsDone()) {
            setError("Abrundung fehlgeschlagen (Radius zu groß?)");
            return nullptr;
        }
        return wrap(mk.Shape(), "Abrundung ergab nichts");
    });
}

OBShape *ob_chamfer(const OBShape *s, const int32_t *edges, int32_t count, double distance) {
    return guarded("Fase", [&]() -> OBShape * {
        if (distance <= 0) {
            setError("Abstand muss größer als 0 sein");
            return nullptr;
        }
        BRepFilletAPI_MakeChamfer mk(s->shape);
        for (int32_t i = 0; i < count; i++) {
            if (edges[i] < 0 || edges[i] >= s->edges.Extent()) continue;
            mk.Add(distance, TopoDS::Edge(s->edges(edges[i] + 1)));
        }
        if (mk.NbContours() == 0) {
            setError("Keine Kanten ausgewählt");
            return nullptr;
        }
        mk.Build();
        if (!mk.IsDone()) {
            setError("Fase fehlgeschlagen (Abstand zu groß?)");
            return nullptr;
        }
        return wrap(mk.Shape(), "Fase ergab nichts");
    });
}

OBShape *ob_shell(const OBShape *s, const int32_t *faces, int32_t count, double thickness) {
    return guarded("Wandstärke", [&]() -> OBShape * {
        if (thickness <= 0) {
            setError("Wandstärke muss größer als 0 sein");
            return nullptr;
        }
        TopTools_ListOfShape remove;
        for (int32_t i = 0; i < count; i++)
            if (faces[i] >= 0 && faces[i] < s->faces.Extent()) remove.Append(s->faces(faces[i] + 1));
        BRepOffsetAPI_MakeThickSolid mk;
        mk.MakeThickSolidByJoin(s->shape, remove, -thickness, 1e-3);
        mk.Build();
        if (!mk.IsDone()) {
            setError("Wandstärke fehlgeschlagen (zu dick?)");
            return nullptr;
        }
        return wrap(mk.Shape(), "Wandstärke ergab nichts");
    });
}

int32_t ob_face_info(const OBShape *s, int32_t index, OBFaceInfo *out) {
    if (!s || index < 0 || index >= s->faces.Extent()) return 0;
    try {
        TopoDS_Face f = TopoDS::Face(s->faces(index + 1));
        bool reversed = f.Orientation() == TopAbs_REVERSED;
        GProp_GProps props;
        BRepGProp::SurfaceProperties(f, props);
        gp_Pnt c = props.CentreOfMass();
        out->centroid[0] = c.X(); out->centroid[1] = c.Y(); out->centroid[2] = c.Z();
        out->area = props.Mass();

        BRepAdaptor_Surface surf(f);
        gp_Pnt p;
        gp_Vec du, dv;
        double um = (surf.FirstUParameter() + surf.LastUParameter()) / 2;
        double vm = (surf.FirstVParameter() + surf.LastVParameter()) / 2;
        surf.D1(um, vm, p, du, dv);
        gp_Vec n = du.Crossed(dv);
        if (surf.GetType() == GeomAbs_Plane) {
            gp_Pln pln = surf.Plane();
            n = gp_Vec(pln.Axis().Direction());
            if (!pln.Direct()) n.Reverse();
            p = pln.Location();
            out->isPlanar = 1;
        } else {
            out->isPlanar = 0;
        }
        if (n.Magnitude() > 1e-12) n.Normalize();
        if (reversed) n.Reverse();
        out->origin[0] = p.X(); out->origin[1] = p.Y(); out->origin[2] = p.Z();
        out->normal[0] = n.X(); out->normal[1] = n.Y(); out->normal[2] = n.Z();
        return 1;
    } catch (...) {
        return 0;
    }
}

int32_t ob_edge_info(const OBShape *s, int32_t index, OBEdgeInfo *out) {
    if (!s || index < 0 || index >= s->edges.Extent()) return 0;
    try {
        TopoDS_Edge e = TopoDS::Edge(s->edges(index + 1));
        if (BRep_Tool::Degenerated(e)) return 0;
        BRepAdaptor_Curve c(e);
        double f = c.FirstParameter(), l = c.LastParameter();
        gp_Pnt a = c.Value(f), b = c.Value(l), m = c.Value((f + l) / 2);
        out->kind = c.GetType() == GeomAbs_Line ? 0 : (c.GetType() == GeomAbs_Circle ? 1 : 2);
        out->start[0] = a.X(); out->start[1] = a.Y(); out->start[2] = a.Z();
        out->end[0] = b.X(); out->end[1] = b.Y(); out->end[2] = b.Z();
        out->midpoint[0] = m.X(); out->midpoint[1] = m.Y(); out->midpoint[2] = m.Z();
        out->length = GCPnts_AbscissaPoint::Length(c);
        return 1;
    } catch (...) {
        return 0;
    }
}

int32_t ob_mesh(const OBShape *s, double linearDeflection, double angularDeflection, OBMesh *out) {
    std::memset(out, 0, sizeof(OBMesh));
    if (!s || s->shape.IsNull()) return 0;
    try {
        BRepMesh_IncrementalMesh mesher(s->shape, linearDeflection, Standard_False, angularDeflection, Standard_True);

        std::vector<float> pos, nrm;
        std::vector<uint32_t> fid, idx;
        for (int32_t fi = 1; fi <= s->faces.Extent(); fi++) {
            TopoDS_Face face = TopoDS::Face(s->faces(fi));
            TopLoc_Location loc;
            Handle(Poly_Triangulation) tri = BRep_Tool::Triangulation(face, loc);
            if (tri.IsNull()) continue;
            if (!tri->HasNormals()) BRepLib_ToolTriangulatedShape::ComputeNormals(face, tri);
            bool reversed = face.Orientation() == TopAbs_REVERSED;
            const gp_Trsf &trsf = loc.Transformation();
            uint32_t base = (uint32_t)(pos.size() / 3);
            for (int i = 1; i <= tri->NbNodes(); i++) {
                gp_Pnt p = tri->Node(i).Transformed(trsf);
                gp_Dir n = tri->HasNormals() ? tri->Normal(i) : gp_Dir(0, 0, 1);
                n.Transform(trsf);
                if (reversed) n.Reverse();
                pos.push_back((float)p.X()); pos.push_back((float)p.Y()); pos.push_back((float)p.Z());
                nrm.push_back((float)n.X()); nrm.push_back((float)n.Y()); nrm.push_back((float)n.Z());
                fid.push_back((uint32_t)(fi - 1));
            }
            for (int t = 1; t <= tri->NbTriangles(); t++) {
                int a, b, c;
                tri->Triangle(t).Get(a, b, c);
                if (reversed) std::swap(b, c);
                idx.push_back(base + a - 1); idx.push_back(base + b - 1); idx.push_back(base + c - 1);
            }
        }

        std::vector<float> ep;
        std::vector<uint32_t> eid;
        for (int32_t ei = 1; ei <= s->edges.Extent(); ei++) {
            TopoDS_Edge e = TopoDS::Edge(s->edges(ei));
            if (BRep_Tool::Degenerated(e)) continue;
            try {
                BRepAdaptor_Curve c(e);
                GCPnts_TangentialDeflection disc(c, angularDeflection, linearDeflection * 0.5);
                for (int i = 1; i < disc.NbPoints(); i++) {
                    gp_Pnt a = disc.Value(i), b = disc.Value(i + 1);
                    ep.insert(ep.end(), {(float)a.X(), (float)a.Y(), (float)a.Z(), (float)b.X(), (float)b.Y(), (float)b.Z()});
                    eid.push_back((uint32_t)(ei - 1));
                }
            } catch (...) {
            }
        }

        auto dup = [](const auto &v) {
            using T = typename std::decay_t<decltype(v)>::value_type;
            T *p = (T *)std::malloc(std::max<size_t>(1, v.size()) * sizeof(T));
            if (!v.empty()) std::memcpy(p, v.data(), v.size() * sizeof(T));
            return p;
        };
        out->positions = dup(pos);
        out->normals = dup(nrm);
        out->faceIds = dup(fid);
        out->vertexCount = (int32_t)fid.size();
        out->indices = dup(idx);
        out->indexCount = (int32_t)idx.size();
        out->edgePoints = dup(ep);
        out->edgeIds = dup(eid);
        out->edgeSegmentCount = (int32_t)eid.size();
        out->faceCount = s->faces.Extent();
        out->edgeCount = s->edges.Extent();
        return 1;
    } catch (const Standard_Failure &e) {
        setError(std::string("Vernetzung: ") + (e.GetMessageString() ? e.GetMessageString() : ""));
    } catch (...) {
        setError("Vernetzung fehlgeschlagen");
    }
    return 0;
}

void ob_mesh_free(OBMesh *m) {
    if (!m) return;
    std::free(m->positions);
    std::free(m->normals);
    std::free(m->faceIds);
    std::free(m->indices);
    std::free(m->edgePoints);
    std::free(m->edgeIds);
    std::memset(m, 0, sizeof(OBMesh));
}

int32_t ob_hlr(const OBShape *s, const double viewDir[3], const double xDir[3], double deflection, OBProjection *out) {
    std::memset(out, 0, sizeof(OBProjection));
    if (!s || s->shape.IsNull()) {
        setError("Nichts zu projizieren");
        return 0;
    }
    try {
        Handle(HLRBRep_Algo) algo = new HLRBRep_Algo();
        algo->Add(s->shape);
        gp_Ax2 ax(gp_Pnt(0, 0, 0), gp_Dir(viewDir[0], viewDir[1], viewDir[2]), gp_Dir(xDir[0], xDir[1], xDir[2]));
        algo->Projector(HLRAlgo_Projector(ax));
        algo->Update();
        algo->Hide();
        HLRBRep_HLRToShape result(algo);

        std::vector<float> pts;
        std::vector<int32_t> starts;
        std::vector<uint8_t> flags;
        std::vector<double> circles;
        std::vector<double> mids;
        std::vector<uint8_t> circleFlags;

        auto collect = [&](const TopoDS_Shape &compound, uint8_t flag) {
            if (compound.IsNull()) return;
            for (TopExp_Explorer ex(compound, TopAbs_EDGE); ex.More(); ex.Next()) {
                TopoDS_Edge e = TopoDS::Edge(ex.Current());
                try {
                    BRepAdaptor_Curve c(e);
                    if (c.GetType() == GeomAbs_Circle) {
                        gp_Circ circ = c.Circle();
                        double f = c.FirstParameter(), l = c.LastParameter();
                        // Projected circles lie in the drawing plane; orientation of the local frame decides direction.
                        // Edges of the HLR result lie in the projection plane, so evaluating the
                        // curve gives the arc's middle point directly in drawing coordinates.
                        gp_Pnt mid = c.Value((f + l) / 2);
                        circles.insert(circles.end(), {circ.Location().X(), circ.Location().Y(), circ.Radius(), l - f, 0.0});
                        mids.insert(mids.end(), {mid.X(), mid.Y()});
                        circleFlags.push_back(flag);
                    }
                    GCPnts_TangentialDeflection disc(c, 0.08, deflection);
                    if (disc.NbPoints() < 2) continue;
                    starts.push_back((int32_t)(pts.size() / 2));
                    for (int i = 1; i <= disc.NbPoints(); i++) {
                        gp_Pnt p = disc.Value(i);
                        pts.push_back((float)p.X());
                        pts.push_back((float)p.Y());
                    }
                    flags.push_back(flag);
                } catch (...) {
                }
            }
        };
        collect(result.VCompound(), 0);
        collect(result.OutLineVCompound(), OB_LINE_OUTLINE);
        collect(result.Rg1LineVCompound(), OB_LINE_SMOOTH);
        collect(result.HCompound(), OB_LINE_HIDDEN);
        collect(result.OutLineHCompound(), OB_LINE_HIDDEN | OB_LINE_OUTLINE);
        starts.push_back((int32_t)(pts.size() / 2));

        auto dup = [](const auto &v) {
            using T = typename std::decay_t<decltype(v)>::value_type;
            T *p = (T *)std::malloc(std::max<size_t>(1, v.size()) * sizeof(T));
            if (!v.empty()) std::memcpy(p, v.data(), v.size() * sizeof(T));
            return p;
        };
        out->points = dup(pts);
        out->pointCount = (int32_t)(pts.size() / 2);
        out->polyStart = dup(starts);
        out->polyFlags = dup(flags);
        out->polyCount = (int32_t)flags.size();
        out->circles = dup(circles);
        out->circleMids = dup(mids);
        out->circleFlags = dup(circleFlags);
        out->circleCount = (int32_t)circleFlags.size();
        return 1;
    } catch (const Standard_Failure &e) {
        setError(std::string("Projektion: ") + (e.GetMessageString() ? e.GetMessageString() : ""));
    } catch (...) {
        setError("Projektion fehlgeschlagen");
    }
    return 0;
}

OBShape *ob_box(const double minP[3], const double maxP[3]) {
    return guarded("Quader", [&]() -> OBShape * {
        return wrap(BRepPrimAPI_MakeBox(toPnt(minP), toPnt(maxP)).Shape(), "Quader ergab nichts");
    });
}

OBShape *ob_plane_face(const double origin[3], const double normal[3], const double xDir[3], double halfSize) {
    return guarded("Schnittebene", [&]() -> OBShape * {
        gp_Ax3 ax(toPnt(origin), gp_Dir(normal[0], normal[1], normal[2]), gp_Dir(xDir[0], xDir[1], xDir[2]));
        return wrap(BRepBuilderAPI_MakeFace(gp_Pln(ax), -halfSize, halfSize, -halfSize, halfSize).Face(), "Schnittebene ergab nichts");
    });
}

int32_t ob_face_outlines(const OBShape *s, const double viewDir[3], const double xDir[3], double deflection, OBProjection *out) {
    std::memset(out, 0, sizeof(OBProjection));
    if (!s || s->shape.IsNull()) return 0;
    try {
        gp_Dir z(viewDir[0], viewDir[1], viewDir[2]), x(xDir[0], xDir[1], xDir[2]);
        gp_Dir y = z.Crossed(x);
        std::vector<float> pts;
        std::vector<int32_t> starts;
        std::vector<uint8_t> flags;
        for (int32_t fi = 1; fi <= s->faces.Extent(); fi++) {
            for (TopExp_Explorer ex(s->faces(fi), TopAbs_EDGE); ex.More(); ex.Next()) {
                TopoDS_Edge e = TopoDS::Edge(ex.Current());
                if (BRep_Tool::Degenerated(e)) continue;
                BRepAdaptor_Curve c(e);
                GCPnts_TangentialDeflection disc(c, 0.08, deflection);
                if (disc.NbPoints() < 2) continue;
                starts.push_back((int32_t)(pts.size() / 2));
                for (int i = 1; i <= disc.NbPoints(); i++) {
                    gp_XYZ p = disc.Value(i).XYZ();
                    pts.push_back((float)p.Dot(x.XYZ()));
                    pts.push_back((float)p.Dot(y.XYZ()));
                }
                flags.push_back((uint8_t)((fi - 1) % 256));
            }
        }
        starts.push_back((int32_t)(pts.size() / 2));
        auto dup = [](const auto &v) {
            using T = typename std::decay_t<decltype(v)>::value_type;
            T *p = (T *)std::malloc(std::max<size_t>(1, v.size()) * sizeof(T));
            if (!v.empty()) std::memcpy(p, v.data(), v.size() * sizeof(T));
            return p;
        };
        out->points = dup(pts);
        out->pointCount = (int32_t)(pts.size() / 2);
        out->polyStart = dup(starts);
        out->polyFlags = dup(flags);
        out->polyCount = (int32_t)flags.size();
        out->circles = (double *)std::malloc(sizeof(double));
        out->circleMids = (double *)std::malloc(sizeof(double));
        out->circleFlags = (uint8_t *)std::malloc(1);
        return 1;
    } catch (...) {
        setError("Umrisse fehlgeschlagen");
        return 0;
    }
}

void ob_projection_free(OBProjection *p) {
    if (!p) return;
    std::free(p->points);
    std::free(p->polyStart);
    std::free(p->polyFlags);
    std::free(p->circles);
    std::free(p->circleMids);
    std::free(p->circleFlags);
    std::memset(p, 0, sizeof(OBProjection));
}

int32_t ob_write_stl(const OBShape *s, const char *path, double linearDeflection, int32_t ascii) {
    if (!s || s->shape.IsNull()) {
        setError("Nichts zu exportieren");
        return 0;
    }
    try {
        BRepMesh_IncrementalMesh mesher(s->shape, linearDeflection, Standard_False, 0.3, Standard_True);
        StlAPI_Writer w;
        w.ASCIIMode() = ascii != 0;
        if (!w.Write(s->shape, path)) {
            setError("STL konnte nicht geschrieben werden");
            return 0;
        }
        return 1;
    } catch (...) {
        setError("STL-Export fehlgeschlagen");
        return 0;
    }
}

int32_t ob_write_step(const OBShape *s, const char *path) {
    if (!s || s->shape.IsNull()) {
        setError("Nichts zu exportieren");
        return 0;
    }
    try {
        STEPControl_Writer w;
        if (w.Transfer(s->shape, STEPControl_AsIs) != IFSelect_RetDone || w.Write(path) != IFSelect_RetDone) {
            setError("STEP konnte nicht geschrieben werden");
            return 0;
        }
        return 1;
    } catch (...) {
        setError("STEP-Export fehlgeschlagen");
        return 0;
    }
}

OBShape *ob_read_step(const char *path) {
    return guarded("STEP-Import", [&]() -> OBShape * {
        STEPControl_Reader r;
        if (r.ReadFile(path) != IFSelect_RetDone) {
            setError("STEP-Datei konnte nicht gelesen werden");
            return nullptr;
        }
        r.TransferRoots();
        return wrap(r.OneShape(), "STEP-Datei enthält keine Geometrie");
    });
}

} // extern "C"
