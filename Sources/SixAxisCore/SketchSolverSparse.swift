import Foundation

/// Large sketches, as they arrive from an imported drawing: thousands of curves with few constraints between them.
/// The dense matrices of the normal path would need gigabytes and minutes here, while each constraint only touches
/// a handful of variables. Small sketches never come here.
extension SketchSolver {
    private struct SparseRow {
        var columns: [Int] = []
        var values: [Double] = []
    }

    /// Same central differences as the dense Jacobian, one sparse row per residual.
    private func sparseJacobian(_ x: inout [Double], _ blocks: [Block]) -> [SparseRow] {
        var rows: [SparseRow] = []
        rows.reserveCapacity(blocks.count)
        for b in blocks {
            var part = [SparseRow](repeating: SparseRow(), count: b.count)
            var plus = [Double](repeating: 0, count: b.count), minus = plus
            for j in b.vars {
                let h = 1e-7 * max(1, abs(x[j]))
                let orig = x[j]
                x[j] = orig + h
                x.withUnsafeBufferPointer { b.eval($0, &plus) }
                x[j] = orig - h
                x.withUnsafeBufferPointer { b.eval($0, &minus) }
                x[j] = orig
                for k in 0..<b.count {
                    let v = b.weight * (plus[k] - minus[k]) / (2 * h)
                    if v != 0 {
                        part[k].columns.append(j)
                        part[k].values.append(v)
                    }
                }
            }
            rows.append(contentsOf: part)
        }
        return rows
    }

    /// Levenberg like the dense path; each step is solved by preconditioned conjugate gradients.
    func levenbergSparse(_ x: inout [Double], blocks: [Block]) -> Bool {
        let n = x.count
        var r = residuals(x, blocks)
        var cost = r.reduce(0) { $0 + $1 * $1 }
        var lambda = 1e-6
        for _ in 0..<30 {
            if (r.map(abs).max() ?? 0) < tolerance * 0.01 { return true }
            let J = sparseJacobian(&x, blocks)
            var g = [Double](repeating: 0, count: n)
            var diagonal = [Double](repeating: 0, count: n)
            for (i, row) in J.enumerated() {
                for (c, v) in zip(row.columns, row.values) {
                    g[c] += v * r[i]
                    diagonal[c] += v * v
                }
            }
            var improved = false
            while lambda < 1e10 {
                let delta = conjugateGradients(J, g: g, diagonal: diagonal, lambda: lambda)
                let xn = zip(x, delta).map { $0 + $1 }
                let rn = residuals(xn, blocks)
                let cn = rn.reduce(0) { $0 + $1 * $1 }
                if cn < cost {
                    let step = delta.map(abs).max() ?? 0
                    x = xn; r = rn; cost = cn
                    lambda = max(lambda / 10, 1e-12)
                    improved = true
                    if step < 1e-13 { return (r.map(abs).max() ?? 0) < tolerance }
                    break
                }
                lambda *= 10
            }
            if !improved { break }
        }
        return (r.map(abs).max() ?? 0) < tolerance
    }

    /// Solves (JᵀJ + λ(I + D)) δ = -g without ever building the matrix.
    private func conjugateGradients(_ J: [SparseRow], g: [Double], diagonal: [Double], lambda: Double) -> [Double] {
        let n = g.count
        let damping = diagonal.map { lambda * (1 + $0) }
        let inverse = zip(diagonal, damping).map { 1 / ($0 + $1) }

        func multiply(_ v: [Double]) -> [Double] {
            var out = [Double](repeating: 0, count: n)
            for row in J {
                var dot = 0.0
                for (c, a) in zip(row.columns, row.values) { dot += a * v[c] }
                if dot != 0 { for (c, a) in zip(row.columns, row.values) { out[c] += a * dot } }
            }
            for i in 0..<n { out[i] += damping[i] * v[i] }
            return out
        }

        var delta = [Double](repeating: 0, count: n)
        var residual = g.map { -$0 }
        var z = zip(inverse, residual).map { $0 * $1 }
        var p = z
        var rz = zip(residual, z).reduce(0) { $0 + $1.0 * $1.1 }
        let target = rz * 1e-24
        for _ in 0..<min(n, 400) where rz > target && rz > 0 {
            let ap = multiply(p)
            let curvature = zip(p, ap).reduce(0) { $0 + $1.0 * $1.1 }
            guard curvature > 0 else { break }
            let alpha = rz / curvature
            for i in 0..<n {
                delta[i] += alpha * p[i]
                residual[i] -= alpha * ap[i]
            }
            z = zip(inverse, residual).map { $0 * $1 }
            let next = zip(residual, z).reduce(0) { $0 + $1.0 * $1.1 }
            let beta = next / rz
            rz = next
            for i in 0..<n { p[i] = z[i] + beta * p[i] }
        }
        return delta
    }

    /// The dense analysis on sparse rows: remaining degrees of freedom and which variables are determined.
    /// Pivots prefer the rarest column, so a chain of arcs causes no fill-in. If a tangle of constraints fills up too
    /// far anyway the answer stays honest: nothing counts as determined and the count is an upper estimate.
    func analyzeFreedomSparse(x: [Double], blocks: [Block], varCount n: Int) -> (Int, [Bool]) {
        var xs = x
        let J = sparseJacobian(&xs, blocks)
        var uses = [Int](repeating: 0, count: n)
        for row in J { for c in row.columns { uses[c] += 1 } }

        var pivotRows: [[Int: Double]] = []      // reduced rows
        var pivotColumn: [Int] = []
        var rowOfPivot: [Int: Int] = [:]
        var rowsWithColumn: [Int: Set<Int>] = [:]
        var budget = 20_000_000

        for sparse in J {
            var row: [Int: Double] = [:]
            for (c, v) in zip(sparse.columns, sparse.values) where abs(v) > 1e-12 { row[c] = v }
            // Take out the pivots of the earlier rows.
            for c in Array(row.keys) {
                guard let p = rowOfPivot[c], let f = row[c] else { continue }
                row[c] = nil
                for (k, v) in pivotRows[p] where k != c {
                    row[k, default: 0] -= f * v
                    budget -= 1
                }
            }
            row = row.filter { abs($0.value) > 1e-8 }
            guard budget > 0 else {
                return (max(n - pivotRows.count, 0), [Bool](repeating: false, count: n))
            }
            guard let largest = row.values.map(abs).max() else { continue }
            guard let pivot = row.filter({ abs($0.value) > largest * 1e-3 }).keys.min(by: { (uses[$0], $0) < (uses[$1], $1) }),
                  let pv = row[pivot] else { continue }
            row[pivot] = nil
            for k in Array(row.keys) { row[k]! /= pv }
            // The new pivot leaves all rows so far (reduced form).
            for p in rowsWithColumn[pivot] ?? [] {
                guard let f = pivotRows[p][pivot] else { continue }
                pivotRows[p][pivot] = nil
                for (k, v) in row {
                    pivotRows[p][k, default: 0] -= f * v
                    rowsWithColumn[k, default: []].insert(p)
                    budget -= 1
                }
            }
            rowsWithColumn[pivot] = nil
            let index = pivotRows.count
            for k in row.keys { rowsWithColumn[k, default: []].insert(index) }
            pivotRows.append(row)
            pivotColumn.append(pivot)
            rowOfPivot[pivot] = index
        }

        var determined = [Bool](repeating: false, count: n)
        for (index, column) in pivotColumn.enumerated() {
            // A pivot is fixed if no free variable reaches it.
            determined[column] = !pivotRows[index].values.contains { abs($0) > 1e-8 }
        }
        return (n - pivotRows.count, determined)
    }
}
