const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const max_items_per_row = 6; // Number of elements to show per row
const max_rows = 8; // Maximum number of rows to show before truncating
const Tensor = @import("tensor.zig").Tensor;
const StabilityError = @import("tensor.zig").StabilityError;
const simdmatmul = @import("matmul.zig");
const Slice = @import("tensor.zig").Slice;
const testing = std.testing;
const expectEqual = testing.expectEqual;
const expectError = testing.expectError;

//--------------------------------- Transformation Operations ---------------------------------

/// Transposes a 2D tensor in-place.
///
/// This function takes a tensor of type `T` and transposes it, effectively
/// swapping its rows and columns. The tensor must be 2-dimensional; otherwise,
/// an `UnsupportedDimension` error is returned.
///
/// The function allocates new memory for the transposed data, copies the
/// transposed elements into this new memory, frees the old data, and updates
/// the tensor's data pointer and shape to reflect the transposition.
///
/// ## Parameters:
/// - `T`: The type of the elements in the tensor.
/// - `tensor`: A pointer to the tensor to be transposed.
///
/// ## Returns:
/// - `!void`: Returns `void` on success, or an error if the tensor is not
///   2-dimensional or if memory allocation fails.
///
/// ## Errors:
/// - `UnsupportedDimension`: The tensor is not 2-dimensional.
/// - Any error that can be returned by the allocator's `alignedAlloc` method.
///
/// ## Example:
/// ```zig
/// const std = @import("std");
/// const Tensor = @import("tensor.zig").Tensor;
/// const allocator = std.heap.page_allocator;
///
/// var tensor = Tensor(f32).init(allocator, .{2, 3});
/// tensor.data[0] = 1.0;
/// tensor.data[1] = 2.0;
/// tensor.data[2] = 3.0;
/// tensor.data[3] = 4.0;
/// tensor.data[4] = 5.0;
/// tensor.data[5] = 6.0;
///
/// try transpose(f32, &tensor);
///
/// // tensor.shape is now .{3, 2}
/// // tensor.data is now .{1.0, 4.0, 2.0, 5.0, 3.0, 6.0}
/// ```
// Tensor Operations
pub fn transpose(comptime T: type, tensor: *Tensor(T)) !void {
    if (tensor.shape.len != 2) return error.UnsupportedDimension;

    const rows = tensor.shape[0];
    const cols = tensor.shape[1];
    var new_data = try tensor.allocator.alignedAlloc(@TypeOf(tensor.data[0]), 32, rows * cols);

    for (0..rows) |i| {
        for (0..cols) |j| {
            new_data[j * rows + i] = tensor.data[i * cols + j];
        }
    }

    tensor.allocator.free(tensor.data);
    tensor.data = new_data;

    // Swap dimensions
    const temp = tensor.shape[0];
    tensor.shape[0] = tensor.shape[1];
    tensor.shape[1] = temp;
}

/// Transposes a tensor by swapping specified dimensions.
///
/// This function takes a tensor and two dimensions, and swaps the specified dimensions
/// to produce a transposed tensor. The function performs the following steps:
/// 1. Validates the dimensions to ensure they are within the bounds of the tensor's shape.
/// 2. Calculates the strides for the current shape of the tensor.
/// 3. Creates a new shape with the specified dimensions swapped.
/// 4. Allocates memory for the transposed data.
/// 5. Calculates the new strides for the transposed shape.
/// 6. Creates coordinate arrays to keep track of the element positions.
/// 7. Performs the transpose operation by iterating over each element, calculating the
///    source coordinates, swapping the coordinates for the transposed dimensions, and
///    copying the data to the new transposed tensor.
/// 8. Updates the tensor with the new data and shape.
///
/// Parameters:
/// - `T`: The type of the elements in the tensor.
/// - `tensor`: A pointer to the tensor to transpose.
/// - `dim0`: The first dimension to swap.
/// - `dim1`: The second dimension to swap.
///
/// Returns:
/// - `!void`: Returns an error if the dimensions are invalid or if memory allocation fails.
///
/// Errors:
/// - `error.InvalidDimension`: If either `dim0` or `dim1` is out of bounds of the tensor's shape.
/// - `error.OutOfMemory`: If memory allocation fails.
pub fn transposeAxes(comptime T: type, tensor: *Tensor(T), dim0: usize, dim1: usize) !void {
    if (dim0 >= tensor.shape.len or dim1 >= tensor.shape.len) {
        return error.InvalidDimension;
    }

    // Calculate strides for the current shape
    var strides = try tensor.allocator.alloc(usize, tensor.shape.len);
    defer tensor.allocator.free(strides);

    strides[tensor.shape.len - 1] = 1;
    var i: usize = tensor.shape.len - 1;
    while (i > 0) : (i -= 1) {
        strides[i - 1] = strides[i] * tensor.shape[i];
    }

    // Create new shape with swapped dimensions
    var new_shape = try tensor.allocator.alloc(usize, tensor.shape.len);
    errdefer tensor.allocator.free(new_shape);

    for (tensor.shape, 0..) |dim, idx| {
        if (idx == dim0) {
            new_shape[idx] = tensor.shape[dim1];
        } else if (idx == dim1) {
            new_shape[idx] = tensor.shape[dim0];
        } else {
            new_shape[idx] = dim;
        }
    }

    // Allocate memory for transposed data
    var new_data = try tensor.allocator.alignedAlloc(T, 32, tensor.data.len);
    errdefer tensor.allocator.free(new_data);

    // Calculate new strides
    var new_strides = try tensor.allocator.alloc(usize, tensor.shape.len);
    defer tensor.allocator.free(new_strides);

    new_strides[tensor.shape.len - 1] = 1;
    i = tensor.shape.len - 1;
    while (i > 0) : (i -= 1) {
        new_strides[i - 1] = new_strides[i] * new_shape[i];
    }

    // Create coordinate arrays
    var coords = try tensor.allocator.alloc(usize, tensor.shape.len);
    defer tensor.allocator.free(coords);
    @memset(coords, 0);

    // Perform the transpose operation
    const total_elements = tensor.data.len;
    var idx: usize = 0;
    while (idx < total_elements) : (idx += 1) {
        // Calculate source coordinates
        var remaining = idx;
        for (0..tensor.shape.len) |dim| {
            coords[dim] = remaining / new_strides[dim];
            remaining = remaining % new_strides[dim];
        }

        // Swap coordinates for the transposed dimensions
        const temp = coords[dim0];
        coords[dim0] = coords[dim1];
        coords[dim1] = temp;

        // Calculate source index using original strides
        var src_idx: usize = 0;
        for (0..tensor.shape.len) |dim| {
            src_idx += coords[dim] * strides[dim];
        }

        new_data[idx] = tensor.data[src_idx];
    }

    // Update tensor with new data and shape
    tensor.allocator.free(tensor.data);
    tensor.data = new_data;
    tensor.allocator.free(tensor.shape);
    tensor.shape = new_shape;
}

/// Accumulates the values of `other` tensor into the `tensor` in-place.
///
/// This function performs an element-wise addition of the `other` tensor to the `tensor`
/// and then accumulates the result in a cumulative sum fashion.
///
/// # Parameters
/// - `T`: The type of the elements in the tensors.
/// - `tensor`: A pointer to the tensor that will be modified in-place.
/// - `other`: The tensor whose values will be added to `tensor`.
///
/// # Returns
/// - `void`: Returns nothing on success.
///
/// # Errors
/// - `ShapeMismatch`: If the shapes of `tensor` and `other` do not match.
///
/// # Example
/// ```zig
/// var tensor = Tensor(f32, .{2, 2}, .{1.0, 2.0, 3.0, 4.0});
/// var other = Tensor(f32, .{2, 2}, .{0.5, 1.5, 2.5, 3.5});
/// try accumulate(f32, &tensor, other);
/// // tensor.data is now {1.5, 4.0, 9.0, 16.0}
/// ```
///
/// # Notes
/// - The function assumes that the `tensor` and `other` have the same shape.
/// - The function performs an in-place modification of the `tensor`.
pub fn accumulate(comptime T: type, tensor: *Tensor(T), other: Tensor(T)) !void {
    if (!std.mem.eql(usize, tensor.shape, other.shape)) {
        std.debug.print("tensor shape: {d}\n", .{tensor.shape});
        std.debug.print("other shape: {d}\n", .{other.shape});
        std.debug.print("Error during accumulation", .{});
        return error.ShapeMismatch;
    }

    var temp = try tensor.copy();
    defer temp.deinit();

    for (tensor.data, 0..) |_, i| {
        tensor.data[i] = temp.data[i] + other.data[i];
        if (i > 0) {
            tensor.data[i] += tensor.data[i - 1];
        }
    }
}

/// Gets a chunk of a tensor along a specified dimension.
///
/// This function divides a tensor into equal-sized chunks along a specified dimension and returns the chunk at the given index.
///
/// # Parameters
/// - `T`: The type of the elements in the tensor.
/// - `tensor`: The input tensor to be chunked.
/// - `dim`: The dimension along which to chunk the tensor.
/// - `chunk_idx`: The index of the chunk to retrieve.
/// - `num_chunks`: The total number of chunks to divide the tensor into.
///
/// # Returns
/// - A tensor containing the specified chunk of the input tensor.
///
/// # Errors
/// - `error.InvalidDimension`: If the specified dimension is out of bounds.
/// - `error.InvalidNumChunks`: If the number of chunks is zero or greater than the size of the specified dimension.
/// - `error.InvalidChunkIndex`: If the chunk index is out of bounds.
/// - `error.UnevenChunkSize`: If the tensor cannot be evenly divided into the specified number of chunks.
///
/// # Example
/// ```zig
/// const tensor = Tensor(f32).initFromSlice(allocator, &[2, 6], &[_]f32{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12});
/// const chunk = try getChunk(f32, tensor, 1, 0, 3);
/// // chunk now contains a tensor with shape [2, 2] and data [1, 2, 3, 4]
/// ```
pub fn getChunk(comptime T: type, tensor: Tensor(T), dim: usize, chunk_idx: usize, num_chunks: usize) !Tensor(T) {
    // Validate inputs
    if (dim >= tensor.shape.len) {
        return error.InvalidDimension;
    }

    const dim_size = tensor.shape[dim];
    if (num_chunks == 0 or dim_size < num_chunks) {
        return error.InvalidNumChunks;
    }

    if (chunk_idx >= num_chunks) {
        return error.InvalidChunkIndex;
    }

    // Calculate chunk size and start/end indices
    const chunk_size = dim_size / num_chunks;
    if (chunk_size * num_chunks != dim_size) {
        return error.UnevenChunkSize;
    }

    const start_idx = chunk_idx * chunk_size;

    // Create new shape array
    var new_shape = try tensor.allocator.alloc(usize, tensor.shape.len);
    errdefer tensor.allocator.free(new_shape);

    for (tensor.shape, 0..) |s, i| {
        new_shape[i] = if (i == dim) chunk_size else s;
    }

    // Create result tensor
    var result = try Tensor(T).init(tensor.allocator, new_shape);
    tensor.allocator.free(new_shape);
    errdefer result.deinit();

    // Calculate strides for the input tensor
    var strides = try tensor.allocator.alloc(usize, tensor.shape.len);
    defer tensor.allocator.free(strides);

    strides[tensor.shape.len - 1] = 1;
    var i = tensor.shape.len - 1;
    while (i > 0) : (i -= 1) {
        strides[i - 1] = strides[i] * tensor.shape[i];
    }

    // Copy data
    const total_elements = result.data.len;
    var result_idx: usize = 0;
    var coords = try tensor.allocator.alloc(usize, tensor.shape.len);
    defer tensor.allocator.free(coords);
    @memset(coords, 0);

    while (result_idx < total_elements) : (result_idx += 1) {
        // Calculate source coordinates
        var temp = result_idx;
        var src_idx: usize = 0;

        for (0..tensor.shape.len) |j| {
            const rev_j = tensor.shape.len - 1 - j;
            if (rev_j == dim) {
                coords[rev_j] = temp % chunk_size + start_idx;
            } else {
                coords[rev_j] = temp % tensor.shape[rev_j];
            }
            src_idx += coords[rev_j] * strides[rev_j];
            temp /= if (rev_j == dim) chunk_size else tensor.shape[rev_j];
        }

        result.data[result_idx] = tensor.data[src_idx];
    }

    return result;
}

/// Concatenates two tensors along a specified dimension.
///
/// This function takes two tensors of the same type and concatenates them along the specified dimension.
/// The resulting tensor will have a shape that is the same as the input tensors, except for the specified
/// dimension, which will be the sum of the sizes of the input tensors along that dimension.
///
/// # Parameters
/// - `T`: The type of the elements in the tensors.
/// - `tensor`: The first tensor to concatenate.
/// - `other`: The second tensor to concatenate.
/// - `dim`: The dimension along which to concatenate the tensors.
///
/// # Returns
/// A new tensor that is the result of concatenating the input tensors along the specified dimension.
///
/// # Errors
/// This function will return an error if the tensors cannot be concatenated due to incompatible shapes or
/// if there is an allocation failure.
///
/// # Example
/// ```zig
/// const std = @import("std");
/// const Tensor = @import("tensor.zig").Tensor;
/// const concat = @import("ops.zig").concat;
///
/// var gpa = std.heap.GeneralPurposeAllocator(.{}){};
/// defer _ = gpa.deinit();
/// const allocator = gpa.allocator;
///
/// var tensor1 = try Tensor(f32).init(allocator, &[_]usize{2, 3});
/// defer tensor1.deinit();
/// tensor1.data = &[_]f32{1.0, 2.0, 3.0, 4.0, 5.0, 6.0};
///
/// var tensor2 = try Tensor(f32).init(allocator, &[_]usize{2, 3});
/// defer tensor2.deinit();
/// tensor2.data = &[_]f32{7.0, 8.0, 9.0, 10.0, 11.0, 12.0};
///
/// const result = try concat(f32, tensor1, tensor2, 0);
/// defer result.deinit();
///
/// // The resulting tensor will have shape [4, 3] and data [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0]
/// std.debug.print("Result shape: {}\n", .{result.shape});
/// std.debug.print("Result data: {}\n", .{result.data});
/// ```
///
/// # Notes
/// - The function assumes that the input tensors have the same shape except for the specified dimension.
/// - The function allocates memory for the new tensor and its shape, so it is important to free the allocated
///   memory using the `deinit` method of the resulting tensor.
pub fn concat(comptime T: type, tensor: Tensor(T), other: Tensor(T), dim: usize) !Tensor(T) {
    // Verify tensors can be concatenated
    try verifyCompatibleForConcat(T, tensor, other, dim);

    // Calculate new shape
    var new_shape = try tensor.allocator.alloc(usize, tensor.shape.len);
    errdefer tensor.allocator.free(new_shape);

    for (tensor.shape, 0..) |s, i| {
        new_shape[i] = if (i == dim) s + other.shape[i] else s;
    }

    // Create new tensor with combined shape
    var result = try Tensor(T).init(tensor.allocator, new_shape);
    errdefer result.deinit();
    tensor.allocator.free(new_shape);

    // Early return for zero-sized tensors
    if (calculateSize(result.shape) == 0) {
        return result;
    }

    // Helper function to get strides
    var strides = try tensor.allocator.alloc(usize, tensor.shape.len);
    defer tensor.allocator.free(strides);

    // Calculate strides for the result tensor
    strides[strides.len - 1] = 1;
    var i: usize = strides.len - 1;
    while (i > 0) {
        i -= 1;
        strides[i] = strides[i + 1] * result.shape[i + 1];
    }

    // Copy data from first tensor
    const first_size = calculateSize(tensor.shape);
    if (first_size > 0) {
        var coords = try tensor.allocator.alloc(usize, tensor.shape.len);
        defer tensor.allocator.free(coords);
        @memset(coords, 0);

        var idx: usize = 0;
        while (idx < first_size) : (idx += 1) {
            // Calculate source and destination indices
            var src_idx: usize = 0;
            var dst_idx: usize = 0;

            for (coords, 0..) |c, j| {
                if (j == dim) {
                    src_idx += c * (if (j + 1 < tensor.shape.len) blk: {
                        var prod: usize = 1;
                        for (j + 1..tensor.shape.len) |k| {
                            prod *= tensor.shape[k];
                        }
                        break :blk prod;
                    } else 1);
                    dst_idx += c * strides[j];
                } else {
                    src_idx += c * (if (j + 1 < tensor.shape.len) blk: {
                        var prod: usize = 1;
                        for (j + 1..tensor.shape.len) |k| {
                            prod *= tensor.shape[k];
                        }
                        break :blk prod;
                    } else 1);
                    dst_idx += c * strides[j];
                }
            }

            result.data[dst_idx] = tensor.data[src_idx];

            // Update coordinates
            var j = coords.len;
            while (j > 0) {
                j -= 1;
                coords[j] += 1;
                if (coords[j] < tensor.shape[j]) break;
                coords[j] = 0;
            }
        }
    }

    // Copy data from second tensor
    const second_size = calculateSize(other.shape);
    if (second_size > 0) {
        var coords = try tensor.allocator.alloc(usize, other.shape.len);
        defer tensor.allocator.free(coords);
        @memset(coords, 0);

        var idx: usize = 0;
        while (idx < second_size) : (idx += 1) {
            // Calculate source and destination indices
            var src_idx: usize = 0;
            var dst_idx: usize = 0;

            for (coords, 0..) |c, j| {
                if (j == dim) {
                    src_idx += c * (if (j + 1 < other.shape.len) blk: {
                        var prod: usize = 1;
                        for (j + 1..other.shape.len) |k| {
                            prod *= other.shape[k];
                        }
                        break :blk prod;
                    } else 1);
                    dst_idx += (c + tensor.shape[dim]) * strides[j];
                } else {
                    src_idx += c * (if (j + 1 < other.shape.len) blk: {
                        var prod: usize = 1;
                        for (j + 1..other.shape.len) |k| {
                            prod *= other.shape[k];
                        }
                        break :blk prod;
                    } else 1);
                    dst_idx += c * strides[j];
                }
            }

            result.data[dst_idx] = other.data[src_idx];

            // Update coordinates
            var j = coords.len;
            while (j > 0) {
                j -= 1;
                coords[j] += 1;
                if (coords[j] < other.shape[j]) break;
                coords[j] = 0;
            }
        }
    }

    return result;
}

fn verifyCompatibleForConcat(comptime T: type, tensor: Tensor(T), other: Tensor(T), dim: usize) !void {
    // Check if dimension is valid
    if (dim >= tensor.shape.len) {
        return error.InvalidDimension;
    }

    // Check if tensors have same number of dimensions
    if (tensor.shape.len != other.shape.len) {
        return error.DimensionMismatch;
    }

    // Check if all dimensions except concat dim are equal
    for (tensor.shape, 0..) |s, i| {
        if (i != dim and s != other.shape[i]) {
            std.debug.print("tensor shape: {d}\n", .{tensor.shape});
            std.debug.print("other shape: {d}\n", .{other.shape});
            return error.IncompatibleShapes;
        }
    }
}

/// Stacks a list of tensors along a specified dimension.
///
/// This function takes a list of tensors with the same shape and stacks them
/// along a new dimension, creating a new tensor with an additional dimension.
///
/// # Parameters
/// - `T`: The type of the elements in the tensors.
/// - `tensors`: A list of tensors to be stacked. All tensors must have the same shape.
/// - `dim`: The dimension along which to stack the tensors. Must be less than or equal to the number of dimensions in the input tensors.
///
/// # Returns
/// - `Tensor(T)`: A new tensor with an additional dimension, containing the stacked tensors.
///
/// # Errors
/// - `error.EmptyTensorList`: If the input list of tensors is empty.
/// - `error.ShapeMismatch`: If the input tensors do not all have the same shape.
/// - `error.InvalidDimension`: If the specified dimension is greater than the number of dimensions in the input tensors.
///
/// # Example
/// ```zig
/// const tensor1 = Tensor(f32).init(...);
/// const tensor2 = Tensor(f32).init(...);
/// const stacked = try stack(f32, &[tensor1, tensor2], 0);
/// ```
///
/// # Notes
/// - The function allocates memory for the new tensor shape and strides, which is freed before returning.
/// - The function calculates the strides for the result tensor to facilitate copying data from the input tensors.
pub fn stack(comptime T: type, tensors: []const Tensor(T), dim: usize) !Tensor(T) {
    if (tensors.len == 0) {
        return error.EmptyTensorList;
    }

    const ref_tensor = tensors[0];
    const ref_shape = ref_tensor.shape;

    // Validate all tensors have the same shape
    for (tensors[1..]) |tensor| {
        if (!std.mem.eql(usize, tensor.shape, ref_shape)) {
            std.debug.print("Error during stacking", .{});
            return error.ShapeMismatch;
        }
    }

    // Validate dimension
    if (dim > ref_shape.len) {
        return error.InvalidDimension;
    }

    // Create new shape with extra dimension
    var new_shape = try ref_tensor.allocator.alloc(usize, ref_shape.len + 1);
    errdefer ref_tensor.allocator.free(new_shape);

    // Copy shape and insert new dimension
    var src_shape_idx: usize = 0;
    var dst_shape_idx: usize = 0;
    while (dst_shape_idx < new_shape.len) : (dst_shape_idx += 1) {
        if (dst_shape_idx == dim) {
            new_shape[dst_shape_idx] = tensors.len; // Size of new dimension
        } else {
            new_shape[dst_shape_idx] = ref_shape[src_shape_idx];
            src_shape_idx += 1;
        }
    }

    // Create result tensor
    var result = try Tensor(T).init(ref_tensor.allocator, new_shape);
    errdefer result.deinit();
    ref_tensor.allocator.free(new_shape);

    // Calculate strides for the result tensor
    var strides = try ref_tensor.allocator.alloc(usize, result.shape.len);
    defer ref_tensor.allocator.free(strides);

    strides[strides.len - 1] = 1;
    var i = strides.len - 1;
    while (i > 0) : (i -= 1) {
        strides[i - 1] = strides[i] * result.shape[i];
    }

    // Copy data from each input tensor
    var coords = try ref_tensor.allocator.alloc(usize, result.shape.len);
    defer ref_tensor.allocator.free(coords);
    @memset(coords, 0);

    const elements_per_tensor = calculateSize(ref_shape);

    // For each input tensor
    for (tensors, 0..) |tensor, tensor_idx| {
        var element_idx: usize = 0;
        while (element_idx < elements_per_tensor) : (element_idx += 1) {
            // Calculate source coordinates (excluding stacked dimension)
            var temp = element_idx;
            var src_coords = try ref_tensor.allocator.alloc(usize, ref_shape.len);
            defer ref_tensor.allocator.free(src_coords);

            var j = ref_shape.len;
            while (j > 0) : (j -= 1) {
                src_coords[j - 1] = temp % ref_shape[j - 1];
                temp /= ref_shape[j - 1];
            }

            // Calculate destination coordinates (including stacked dimension)
            var final_dst_idx: usize = 0;
            var coord_idx: usize = 0;
            for (coords, 0..) |*c, idx| {
                if (idx == dim) {
                    c.* = tensor_idx;
                } else {
                    c.* = src_coords[coord_idx];
                    coord_idx += 1;
                }
                final_dst_idx += c.* * strides[idx];
            }

            // Copy the value
            result.data[final_dst_idx] = tensor.data[element_idx];

            // Update coordinates for next iteration
            var k = coords.len;
            while (k > 0) {
                k -= 1;
                if (k == dim) continue; // Skip the stacked dimension
                coords[k] += 1;
                if (coords[k] < result.shape[k]) break;
                coords[k] = 0;
            }
        }
    }

    return result;
}

/// Convert a potentially negative dimension index to a positive index.
///
/// This function takes a dimension index `dim` which can be negative, and the total number of dimensions `n_dims`.
/// If `dim` is negative, it is converted to a positive index by adding it to `n_dims`.
/// If the resulting index is out of bounds, an `InvalidDimension` error is returned.
///
/// Parameters:
/// - `dim`: The dimension index, which can be negative.
/// - `n_dims`: The total number of dimensions, which must be a positive integer.
///
/// Returns:
/// - The positive dimension index if `dim` is within bounds.
///
/// Errors:
/// - `InvalidDimension`: If the resulting dimension index is out of bounds.
pub fn normalizeDim(dim: isize, n_dims: usize) !usize {
    const n_dims_i: isize = @intCast(n_dims);
    if (dim >= 0) {
        if (dim >= n_dims_i) return error.InvalidDimension;
        return @intCast(dim);
    } else {
        const positive_dim = n_dims_i + dim; // -1 becomes n_dims-1
        if (positive_dim < 0 or positive_dim >= n_dims_i) return error.InvalidDimension;
        return @intCast(positive_dim);
    }
}

/// Flattens dimensions from start_dim to end_dim (inclusive)
/// TODO: Convert to tensor intrinsic
pub fn flatten(comptime T: type, tensor: *Tensor(T), start_dim: isize, end_dim: isize) !void {
    const positive_start = try normalizeDim(start_dim, tensor.shape.len);
    const positive_end = try normalizeDim(end_dim, tensor.shape.len);

    if (positive_start > positive_end) {
        return error.InvalidDimRange;
    }

    // Calculate the size of the flattened dimension
    var flat_size: usize = 1;
    for (positive_start..positive_end + 1) |i| {
        flat_size *= tensor.shape[i];
    }

    // Create new shape
    const new_shape_len = tensor.shape.len - (positive_end - positive_start);
    var new_shape = try tensor.allocator.alloc(usize, new_shape_len);
    errdefer tensor.allocator.free(new_shape);

    // Copy dimensions before flattened dimensions
    @memcpy(new_shape[0..positive_start], tensor.shape[0..positive_start]);

    // Add flattened dimension
    new_shape[positive_start] = flat_size;

    // Copy dimensions after flattened dimensions
    if (positive_end + 1 < tensor.shape.len) {
        @memcpy(
            new_shape[positive_start + 1 ..],
            tensor.shape[positive_end + 1 ..],
        );
    }

    // Free old shape and update with new shape
    tensor.allocator.free(tensor.shape);
    tensor.shape = new_shape;
}

// Usage example:
pub fn stackAndFlatten(comptime T: type, r: Tensor(T), i: Tensor(T), dim: isize) !Tensor(T) {
    // Convert negative dimension to positive
    const positive_dim = if (dim >= 0)
        @as(usize, @intCast(dim))
    else blk: {
        const n_dims: isize = @intCast(r.shape.len);
        // -1 means last dimension + 1 (where we'll insert)
        const adjusted_dim = n_dims + 1 + dim;
        if (adjusted_dim < 0) return error.InvalidDimension;
        break :blk @as(usize, @intCast(adjusted_dim));
    };

    // Stack the tensors along specified dimension
    var tensors = [_]Tensor(T){ r, i };
    var result = try stack(T, &tensors, positive_dim);
    errdefer result.deinit();

    // Flatten the last two dimensions
    try flatten(T, &result, @intCast(result.shape.len - 2), @intCast(result.shape.len - 1));

    return result;
}

fn calculateSize(shape: []const usize) usize {
    var size: usize = 1;
    for (shape) |dim| {
        size *= dim;
    }
    return size;
}

/// Generates a tensor with random values between -1 and 1.
///
/// This function creates a tensor of the specified shape and fills it with
/// random values of type `T` between -1 and 1 using a seeded random number generator.
///
/// - Parameters:
///   - T: The type of the elements in the tensor.
///   - allocator: The allocator to use for memory allocation.
///   - shape: The shape of the tensor as an array of `usize`.
///   - seed: The seed for the random number generator.
/// - Returns: A tensor of type `T` with random values between -1 and 1.
/// - Throws: Returns an error if tensor initialization fails.
pub fn randomTensor(comptime T: type, allocator: std.mem.Allocator, shape: []const usize, seed: u64) !Tensor(T) {
    var tensor = try Tensor(T).init(allocator, shape);
    errdefer tensor.deinit();

    var rng = std.rand.DefaultPrng.init(seed);
    for (tensor.data) |*val| {
        val.* = rng.random().float(T) * 2.0 - 1.0; // Values between -1 and 1
    }
    return tensor;
}

/// Creates a tensor filled with zeros.
///
/// This function allocates memory for a tensor of the specified shape and initializes all elements to zero.
///
/// Parameters:
/// - `T`: The type of the elements in the tensor.
/// - `allocator`: The allocator to use for memory allocation.
/// - `shape`: An array specifying the shape of the tensor.
///
/// Returns:
/// - A `Tensor(T)` instance with all elements initialized to zero.
///
/// Errors:
/// - Returns an error if memory allocation fails.
///
/// Example:
/// ```zig
/// const std = @import("std");
/// const Tensor = @import("tensor.zig").Tensor;
/// const zeros = @import("ops.zig").zeros;
///
/// const allocator = std.heap.page_allocator;
/// const shape = &[_]usize{2, 3};
/// const tensor = try zeros(f32, allocator, shape);
/// defer tensor.deinit();
/// ```
pub fn zeros(comptime T: type, allocator: Allocator, shape: []const usize) !Tensor(T) {
    // Calculate total size
    var total_size: usize = 1;
    for (shape) |dim| {
        total_size *= dim;
    }

    // Allocate aligned data array
    const alignment = 32;
    const data = try allocator.alignedAlloc(T, alignment, total_size);
    // Initialize all elements to zero
    @memset(data, 0);

    // Create tensor shape
    const tensor_shape = try allocator.alloc(usize, shape.len);
    @memcpy(tensor_shape, shape);

    // Return initialized tensor
    return Tensor(T){
        .data = data,
        .shape = tensor_shape,
        .allocator = allocator,
    };
}

// ----------------------- Safety Checks ----------------------------

/// Calculate the index in a flattened array from n-dimensional coordinates.
///
/// This function takes the shape of an n-dimensional array and the coordinates
/// within that array, and calculates the corresponding index in the flattened
/// (1-dimensional) representation of the array.
///
/// # Parameters
/// - `shape`: A slice of `usize` representing the dimensions of the n-dimensional array.
/// - `coords`: A slice of `usize` representing the coordinates within the n-dimensional array.
///
/// # Returns
/// - `usize`: The index in the flattened array corresponding to the given coordinates.
///
/// # Example
/// ```zig
/// const shape = [_]usize{3, 4, 5}; // 3x4x5 array
/// const coords = [_]usize{2, 1, 3}; // Coordinates in the 3x4x5 array
/// const index = calculateIndex(shape, coords); // index will be 53
/// ```
// Calculate index in flattened array from n-dimensional coordinates
pub fn calculateIndex(shape: []const usize, coords: []const usize) usize {
    var index: usize = 0;
    var stride: usize = 1;
    var i: usize = shape.len;
    while (i > 0) {
        i -= 1;
        index += coords[i] * stride;
        stride *= shape[i];
    }
    return index;
}

/// Checks the stability of the given tensor by inspecting its elements for NaN, positive infinity, and negative infinity values.
///
/// This function retrieves stability information for the tensor and returns an appropriate error if any instability is detected.
///
/// Parameters:
/// - `T`: The type of the elements in the tensor.
/// - `tensor`: The tensor to be checked.
///
/// Returns:
/// - `StabilityError.HasNaN` if the tensor contains NaN values.
/// - `StabilityError.HasPositiveInfinity` if the tensor contains positive infinity values.
/// - `StabilityError.HasNegativeInfinity` if the tensor contains negative infinity values.
///
/// Errors:
/// - Returns an error if the stability information cannot be retrieved.
pub fn checkStability(comptime T: type, tensor: Tensor(T)) !void {
    const info = try getStabilityInfo(T, tensor);
    if (info.has_nan) {
        return StabilityError.HasNaN;
    }
    if (info.has_pos_inf) {
        return StabilityError.HasPositiveInfinity;
    }
    if (info.has_neg_inf) {
        return StabilityError.HasNegativeInfinity;
    }
}

/// Analyzes the stability of a tensor by checking for NaN, positive infinity, and negative infinity values.
///
/// This function iterates over the elements of the given tensor and collects information about the presence
/// of NaN, positive infinity, and negative infinity values. It returns a `StabilityInfo` struct containing
/// the results of this analysis.
///
/// ## Parameters
/// - `T`: The type of the elements in the tensor. This is a compile-time parameter.
/// - `tensor`: The tensor to be analyzed.
///
/// ## Returns
/// - `Tensor(T).StabilityInfo`: A struct containing information about the stability of the tensor, including
///   counts and indices of NaN, positive infinity, and negative infinity values.
///
/// ## Errors
/// This function does not return any errors.
///
/// ## Example
/// ```zig
/// const tensor = Tensor(f32){ .data = [_]f32{ 1.0, std.math.nan, std.math.inf, -std.math.inf } };
/// const info = try getStabilityInfo(f32, tensor);
pub fn getStabilityInfo(comptime T: type, tensor: Tensor(T)) !Tensor(T).StabilityInfo {
    var info = Tensor(@TypeOf(tensor.data[0])).StabilityInfo{};

    switch (@typeInfo(@TypeOf(tensor.data[0]))) {
        .Float => {
            for (tensor.data, 0..) |value, i| {
                if (std.math.isNan(value)) {
                    info.has_nan = true;
                    info.nan_count += 1;
                    if (info.first_nan_index == null) {
                        info.first_nan_index = i;
                    }
                } else if (std.math.isPositiveInf(value)) {
                    info.has_pos_inf = true;
                    info.pos_inf_count += 1;
                    if (info.first_pos_inf_index == null) {
                        info.first_pos_inf_index = i;
                    }
                } else if (std.math.isNegativeInf(value)) {
                    info.has_neg_inf = true;
                    info.neg_inf_count += 1;
                    if (info.first_neg_inf_index == null) {
                        info.first_neg_inf_index = i;
                    }
                }
            }
        },
        else => {},
    }

    return info;
}

/// Checks if the given tensor is stable, meaning it does not contain any NaN, positive infinity, or negative infinity values.
///
/// This function retrieves stability information for the tensor and verifies that it does not contain any NaN, positive infinity, or negative infinity values.
///
/// - Parameters:
///   - T: The type of the elements in the tensor.
///   - tensor: The tensor to check for stability.
/// - Returns: A boolean indicating whether the tensor is stable.
/// - Throws: An error if retrieving the stability information fails.
pub fn isStable(comptime T: type, tensor: Tensor(T)) !bool {
    const info = try getStabilityInfo(T, tensor);
    return !info.has_nan and !info.has_pos_inf and !info.has_neg_inf;
}

/// Checks if the given tensor contains any NaN (Not-a-Number) values.
///
/// This function takes a tensor of a specified type and checks if it contains
/// any NaN values. It returns a boolean indicating the presence of NaN values.
///
/// - Parameters:
///   - T: The type of the elements in the tensor.
///   - tensor: The tensor to be checked for NaN values.
/// - Returns: A boolean indicating whether the tensor contains NaN values.
/// - Throws: An error if there is an issue retrieving stability information for the tensor.
pub fn hasNaN(comptime T: type, tensor: Tensor(T)) !bool {
    const info = try getStabilityInfo(T, tensor);
    return info.has_nan;
}

/// Checks if the given tensor contains any positive or negative infinity values.
///
/// This function examines the stability information of the tensor to determine
/// if it contains any positive or negative infinity values.
///
/// - Parameters:
///   - T: The type of the elements in the tensor.
///   - tensor: The tensor to be checked for infinity values.
///
/// - Returns: A boolean indicating whether the tensor contains any positive or
///   negative infinity values.
///
/// - Throws: An error if retrieving the stability information fails.
pub fn hasInf(comptime T: type, tensor: Tensor(T)) !bool {
    const info = try getStabilityInfo(T, tensor);
    return info.has_pos_inf or info.has_neg_inf;
}

/// Replaces all NaN or Infinity values in the given tensor with a specified replacement value.
/// This function only operates on tensors with floating-point data types.
///
/// ## Parameters:
/// - `T`: The type of the elements in the tensor. This must be a floating-point type.
/// - `tensor`: A pointer to the tensor whose NaN or Infinity values are to be replaced.
/// - `replacement`: The value to replace NaN or Infinity values with.
///
/// ## Errors:
/// This function does not return any errors.
///
/// ## Example:
/// ```zig
/// const std = @import("std");
/// const Tensor = @import("tensor.zig").Tensor;
/// const ops = @import("ops.zig");
///
/// var tensor = Tensor(f32).init([3]f32{ std.math.nan, 1.0, std.math.inf });
/// try ops.replaceUnstable(f32, &tensor, 0.0);
/// assert(tensor.data[0] == 0.0);
/// assert(tensor.data[2] == 0.0);
/// ```
pub fn replaceUnstable(comptime T: type, tensor: *Tensor(T), replacement: T) !void {
    switch (@typeInfo(@TypeOf(tensor.data[0]))) {
        .Float => {
            for (tensor.data) |*value| {
                if (std.math.isNan(value.*) or std.math.isInf(value.*)) {
                    value.* = replacement;
                }
            }
        },
        else => {},
    }
}

// ------------------------ Math Operations --------------------------------------

/// Adds the elements of one tensor to another tensor element-wise.
///
/// This function performs an element-wise addition of the elements in `other` tensor
/// to the corresponding elements in the `tensor`. Both tensors must have the same shape.
///
/// If the shapes of the two tensors do not match, an error of type `ShapeMismatch` is returned.
///
/// # Parameters
/// - `T`: The type of the elements in the tensors.
/// - `tensor`: A pointer to the tensor to which the elements of `other` will be added.
/// - `other`: The tensor whose elements will be added to `tensor`.
///
/// # Errors
/// - `ShapeMismatch`: Returned if the shapes of the two tensors do not match.
///
/// # Example
/// ```zig
/// const std = @import("std");
/// const Tensor = @import("tensor.zig").Tensor;
/// const add = @import("ops.zig").add;
///
/// var tensor1 = Tensor(f32, .{2, 2}, .{1.0, 2.0, 3.0, 4.0});
/// var tensor2 = Tensor(f32, .{2, 2}, .{5.0, 6.0, 7.0, 8.0});
///
/// try add(f32, &tensor1, tensor2);
/// // tensor1 now contains {6.0, 8.0, 10.0, 12.0}
/// ```
///
/// # Notes
/// - The function assumes that the `tensor` and `other` have the same shape and does not perform any broadcasting.
pub fn add(comptime T: type, tensor: *Tensor(T), other: Tensor(T)) !void {
    if (!std.mem.eql(usize, tensor.shape, other.shape)) {
        std.debug.print("tensor shape: {d}\n", .{tensor.shape});
        std.debug.print("other shape: {d}\n", .{other.shape});
        std.debug.print("Error during addition", .{});
        return error.ShapeMismatch;
    }

    for (tensor.data, 0..) |_, i| {
        tensor.data[i] += other.data[i];
    }
}

/// Subtracts the elements of one tensor from another tensor element-wise.
///
/// This function performs an element-wise subtraction of the `other` tensor from the `tensor`.
/// Both tensors must have the same shape for the operation to be valid.
///
/// # Parameters
/// - `T`: The type of the elements in the tensors.
/// - `tensor`: A pointer to the tensor from which elements will be subtracted. The result will be stored in this tensor.
/// - `other`: The tensor whose elements will be subtracted from the `tensor`.
///
/// # Returns
/// - `void`: If the operation is successful.
/// - `error.ShapeMismatch`: If the shapes of the two tensors do not match.
///
/// # Errors
/// This function returns an error if the shapes of the two tensors do not match. The error returned is `error.ShapeMismatch`.
///
/// # Example
/// ```zig
/// const T = f32;
/// var tensor1 = Tensor(T){ .shape = [2]usize{2, 2}, .data = [4]T{1.0, 2.0, 3.0, 4.0} };
/// const tensor2 = Tensor(T){ .shape = [2]usize{2, 2}, .data = [4]T{0.5, 1.5, 2.5, 3.5} };
/// try subtract(T, &tensor1, tensor2);
/// // tensor1.data is now [0.5, 0.5, 0.5, 0.5]
/// ```
pub fn subtract(comptime T: type, tensor: *Tensor(T), other: Tensor(T)) !void {
    if (!std.mem.eql(usize, tensor.shape, other.shape)) {
        std.debug.print("tensor shape: {d}\n", .{tensor.shape});
        std.debug.print("other shape: {d}\n", .{other.shape});
        std.debug.print("Error during subtraction", .{});
        return error.ShapeMismatch;
    }

    for (tensor.data, 0..) |_, i| {
        tensor.data[i] -= other.data[i];
    }
}

/// Multiplies the elements of two tensors element-wise and stores the result in the first tensor.
///
/// This function performs an element-wise multiplication of the elements in `tensor` and `other`.
/// The result of the multiplication is stored in `tensor`.
///
/// # Parameters
/// - `T`: The type of the elements in the tensors.
/// - `tensor`: A pointer to the first tensor, which will store the result of the multiplication.
/// - `other`: The second tensor to be multiplied with the first tensor.
///
/// # Returns
/// - `void`: Returns nothing on success.
/// - `error.ShapeMismatch`: If the shapes of the two tensors do not match.
///
/// # Errors
/// This function returns an error if the shapes of the two tensors do not match. The shapes must be equal
/// for the element-wise multiplication to be performed.
///
/// # Example
/// ```zig
/// const T = f32;
/// var tensor1 = Tensor(T, .{2, 2}, .{1.0, 2.0, 3.0, 4.0});
/// const tensor2 = Tensor(T, .{2, 2}, .{5.0, 6.0, 7.0, 8.0});
/// try multiply(T, &tensor1, tensor2);
/// // tensor1.data is now .{5.0, 12.0, 21.0, 32.0}
/// ```
pub fn multiply(comptime T: type, tensor: *Tensor(T), other: Tensor(T)) !void {
    if (!std.mem.eql(usize, tensor.shape, other.shape)) {
        std.debug.print("tensor shape: {d}\n", .{tensor.shape});
        std.debug.print("other shape: {d}\n", .{other.shape});
        std.debug.print("Error during multiplication", .{});
        return error.ShapeMismatch;
    }

    for (tensor.data, 0..) |_, i| {
        tensor.data[i] *= other.data[i];
    }
}

/// Adds a scalar value to each element in the tensor.
///
/// This function iterates over each element in the tensor and adds the given scalar value to it.
///
/// Parameters:
/// - `T`: The type of the elements in the tensor.
/// - `tensor`: A pointer to the tensor to which the scalar value will be added.
/// - `scalar`: The scalar value to add to each element in the tensor.
///
/// Example:
/// ```zig
/// const tensor = Tensor(f32, .{1.0, 2.0, 3.0});
/// scalarAdd(f32, &tensor, 1.0);
pub fn scalarAdd(comptime T: type, tensor: *Tensor(T), scalar: T) void {
    for (tensor.data, 0..) |_, i| {
        tensor.data[i] += scalar;
    }
}

/// Multiplies each element in the given tensor by a scalar value.
///
/// This function iterates over all elements in the tensor and multiplies each
/// element by the provided scalar value, modifying the tensor in place.
///
/// - Parameters:
///   - T: The type of the elements in the tensor. This is a compile-time parameter.
///   - tensor: A pointer to the tensor to be modified. The tensor's data will be
///     multiplied by the scalar value.
///   - scalar: The scalar value to multiply each element in the tensor by.
///
/// # Example
///
/// ```zig
/// const Tensor = @import("tensor.zig").Tensor;
/// const ops = @import("ops.zig");
///
/// var tensor = Tensor(f32, .{1.0, 2.0, 3.0});
/// ops.scalarMultiply(f32, &tensor, 2.0);
/// // tensor.data is now {2.0, 4.0, 6.0}
/// ```
pub fn scalarMultiply(comptime T: type, tensor: *Tensor(T), scalar: T) void {
    for (tensor.data, 0..) |_, i| {
        tensor.data[i] *= scalar;
    }
}

/// Performs broadcasted addition between two tensors.
/// The smaller tensor is broadcast to match the shape of the larger tensor along
/// matching dimensions from right to left.
/// For example: [seq_len, dim] + [dim] -> broadcasts [dim] across seq_len
///
/// # Parameters
/// - `T`: The type of the elements in the tensors.
/// - `a`: A pointer to the larger tensor which will be modified in place.
/// - `b`: The smaller tensor which will be broadcast and added to `a`.
///
/// # Returns
/// - `!void`: Returns an error if the shapes are not compatible for broadcasting.
///
/// # Errors
/// - `error.InvalidBroadcast`: If the shape of `b` is larger than the shape of `a`.
/// - `error.IncompatibleBroadcast`: If the shapes of `a` and `b` are not compatible for broadcasting.
///
/// # Example
/// ```zig
/// const T = f32;
/// var a = Tensor(T, .{2, 3}, .{1.0, 2.0, 3.0, 4.0, 5.0, 6.0});
/// const b = Tensor(T, .{3}, .{0.5, 1.5, 2.5});
/// try broadcast_add(T, &a, b);
/// // a.data is now {1.5, 3.5, 5.5, 4.5, 6.5, 8.5}
/// ```
///
/// This function first checks if the shapes of the tensors are compatible for broadcasting.
/// If they are, it performs the addition in place, modifying the larger tensor `a`.
/// It handles both the common case of adding a 1D tensor to each row of a 2D tensor,
/// as well as the general case for tensors of any shape.
pub fn broadcast_add(comptime T: type, a: *Tensor(T), b: Tensor(T)) !void {
    // Check that shapes can be broadcast
    if (b.shape.len > a.shape.len) {
        return error.InvalidBroadcast;
    }

    // Check that dimensions match from right to left
    for (0..b.shape.len) |i| {
        const a_dim = a.shape[a.shape.len - 1 - i];
        const b_dim = b.shape[b.shape.len - 1 - i];
        if (b_dim != a_dim and b_dim != 1) {
            return error.IncompatibleBroadcast;
        }
    }

    // For common case of [seq_len, dim] + [dim]
    if (a.shape.len == 2 and b.shape.len == 1 and b.shape[0] == a.shape[1]) {
        const seq_len = a.shape[0];
        const dim = a.shape[1];

        // Add bias to each row
        var i: usize = 0;
        while (i < seq_len) : (i += 1) {
            const row_start = i * dim;
            for (0..dim) |j| {
                a.data[row_start + j] += b.data[j];
            }
        }
        return;
    }

    // Handle general case
    const total_elements = blk: {
        var prod: usize = 1;
        for (a.shape) |dim| {
            prod *= dim;
        }
        break :blk prod;
    };

    // For each element in the output
    var i: usize = 0;
    while (i < total_elements) : (i += 1) {
        // Calculate indices for both tensors
        var a_coords = try a.allocator.alloc(usize, a.shape.len);
        defer a.allocator.free(a_coords);
        var temp = i;

        // Convert flat index to coordinates
        for (0..a.shape.len) |j| {
            const rev_j = a.shape.len - 1 - j;
            a_coords[rev_j] = temp % a.shape[rev_j];
            temp /= a.shape[rev_j];
        }

        // Calculate corresponding b index
        var b_idx: usize = 0;
        var b_stride: usize = 1;

        for (0..b.shape.len) |j| {
            const b_j = b.shape.len - 1 - j;
            const a_j = a.shape.len - 1 - j;
            const coord = a_coords[a_j] % b.shape[b_j];
            b_idx += coord * b_stride;
            b_stride *= b.shape[b_j];
        }

        // Add values
        a.data[i] += b.data[b_idx];
    }
}

/// Helper function for broadcasting multiplication.
///
/// This function performs element-wise multiplication of two tensors, `a` and `b`,
/// with broadcasting support. The result is stored back in tensor `a`.
///
/// - Parameters:
///   - T: The type of the elements in the tensors.
///   - a: A pointer to the tensor `a` which will be modified to store the result.
///   - b: The tensor `b` which will be broadcasted and multiplied with tensor `a`.
///
/// - Returns: This function returns an error if the copy operation for the temporary
///   result tensor fails.
///
/// - Note: The function assumes that the dimensions of tensor `b` are compatible
///   for broadcasting with tensor `a`. The broadcasting is performed by repeating
///   the elements of tensor `b` as necessary to match the size of tensor `a`.
///
/// Example:
/// ```zig
/// const T = f32;
/// var a = Tensor(T, .{1.0, 2.0, 3.0, 4.0});
/// const b = Tensor(T, .{2.0});
/// try broadcast_multiply(T, &a, b);
/// // a.data is now {2.0, 4.0, 6.0, 8.0}
/// ```
// Helper function for broadcasting multiplication
pub fn broadcast_multiply(comptime T: type, a: *Tensor(T), b: Tensor(T)) !void {
    // Create a temporary tensor for the result
    var result = try a.copy();
    defer result.deinit();

    // Perform broadcasted multiplication
    const total_elements = a.data.len;
    const b_elements = b.data.len;

    for (0..total_elements) |i| {
        // Calculate the broadcast index for b
        const b_idx = i % b_elements;
        result.data[i] = a.data[i] * b.data[b_idx];
    }

    // Copy result back to a
    @memcpy(a.data, result.data);
}

/// Helper function for broadcasting subtraction.
///
/// This function performs element-wise subtraction of two tensors, where the second tensor
/// is broadcasted to match the shape of the first tensor. The result is stored back in the
/// first tensor.
///
/// - Parameters:
///   - T: The type of the elements in the tensors.
///   - a: A pointer to the first tensor, which will be modified to store the result.
///   - b: The second tensor, which will be broadcasted and subtracted from the first tensor.
///
/// - Returns: An error if the operation fails.
///
/// - Errors:
///   - Any error that can be returned by the `copy` method of the tensor.
///
/// - Note: The function assumes that the dimensions of the tensors are compatible for broadcasting.
// Helper function for broadcasting subtraction
pub fn broadcast_subtract(comptime T: type, a: *Tensor(T), b: Tensor(T)) !void {
    var result = try a.copy();
    defer result.deinit();

    const total_elements = a.data.len;
    const b_elements = b.data.len;

    for (0..total_elements) |i| {
        const b_idx = i % b_elements;
        result.data[i] = a.data[i] - b.data[b_idx];
    }

    @memcpy(a.data, result.data);
}

/// Multiplies two 2D tensors (matrices) and returns the resulting tensor.
///
/// This function performs matrix multiplication on two input tensors. The input tensors must be 2-dimensional
/// and their inner dimensions must be compatible for matrix multiplication (i.e., the number of columns in the
/// first tensor must equal the number of rows in the second tensor).
///
/// - Parameters:
///   - T: The element type of the tensors.
///   - tensor: A pointer to the first tensor (left operand) of type `Tensor(T)`.
///   - other: The second tensor (right operand) of type `Tensor(T)`.
///
/// - Returns: A new tensor of type `Tensor(T)` containing the result of the matrix multiplication.
///
/// - Errors:
///   - `UnsupportedDimension`: If either of the input tensors is not 2-dimensional.
///   - `IncompatibleDimensions`: If the inner dimensions of the input tensors are not compatible for matrix multiplication.
///
/// - Example:
/// ```zig
/// const result = try matmul(f32, &tensorA, tensorB);
/// ```
///
/// - Note: The function assumes that the input tensors are properly initialized and allocated.
pub fn matmul(comptime T: type, tensor: *Tensor(T), other: Tensor(T)) !Tensor(T) {
    if (tensor.shape.len != 2 or other.shape.len != 2) {
        return error.UnsupportedDimension;
    }
    if (tensor.shape[1] != other.shape[0]) {
        return error.IncompatibleDimensions;
    }

    const m = tensor.shape[0];
    const k = tensor.shape[1];
    const n = other.shape[1];

    var result = try Tensor(@TypeOf(tensor.data[0])).init(tensor.allocator, &[_]usize{ m, n });

    for (0..m) |i| {
        for (0..n) |j| {
            var sum: @TypeOf(tensor.data[0]) = 0;
            for (0..k) |l| {
                sum += tensor.data[i * k + l] * other.data[l * n + j];
            }
            result.data[i * n + j] = sum;
        }
    }

    return result;
}

/// Computes the outer product of two 1-dimensional tensors.
///
/// The outer product of two vectors `tensor` and `other` is a matrix where each element
/// `(i, j)` is the product of `tensor[i]` and `other[j]`.
///
/// # Parameters
/// - `T`: The type of the elements in the tensors.
/// - `tensor`: The first input tensor, which must be 1-dimensional.
/// - `other`: The second input tensor, which must be 1-dimensional.
///
/// # Returns
/// - A new tensor representing the outer product of `tensor` and `other`.
///
/// # Errors
/// - `error.InvalidDimensions`: If either `tensor` or `other` is not 1-dimensional.
///
/// # Example
/// ```zig
/// const T = f32;
/// const tensor1 = try Tensor(T).init(allocator, &[_]T{1.0, 2.0});
/// const tensor2 = try Tensor(T).init(allocator, &[_]T{3.0, 4.0});
/// const result = try outer(T, tensor1, tensor2);
/// defer {
///     tensor1.deinit();
///     tensor2.deinit();
///     result.deinit();
/// }
/// // result is a 2x2 tensor with values:
/// // [[3.0, 4.0],
/// //  [6.0, 8.0]]
/// ```
///
/// # Notes
/// - The function assumes that the input tensors are properly initialized and deinitialized.
pub fn outer(comptime T: type, tensor: Tensor(T), other: Tensor(T)) !Tensor(T) {
    if (tensor.shape.len != 1 or other.shape.len != 1) {
        return error.InvalidDimensions;
    }

    const m = tensor.shape[0];
    const n = other.shape[0];

    var result = try Tensor(@TypeOf(tensor.data[0])).init(tensor.allocator, &[_]usize{ m, n });
    errdefer result.deinit();

    for (0..m) |i| {
        for (0..n) |j| {
            result.data[i * n + j] = tensor.data[i] * other.data[j];
        }
    }

    return result;
}

// ------------------------ Machine Learning --------------------------------------

/// Applies Layer Normalization to the input tensor.
///
/// Layer Normalization normalizes the input tensor along the last dimension
/// and scales it using the provided weight and bias tensors. This function
/// also includes stability checks to ensure numerical stability during the
/// normalization process.
///
/// # Parameters
///
/// - `T`: The data type of the tensor elements (e.g., `f32`, `f64`).
/// - `input`: The input tensor to be normalized.
/// - `weight`: The weight tensor used for scaling the normalized values.
/// - `bias`: The bias tensor added to the scaled values.
/// - `eps`: A small value added to the variance for numerical stability.
///
/// # Returns
///
/// - `Tensor(T)`: The normalized tensor with the same shape as the input tensor.
///
/// # Errors
///
/// - `error.InvalidEpsilon`: If `eps` is less than or equal to zero.
/// - `error.InvalidShape`: If the input tensor has less than one dimension.
/// - `error.InvalidWeightShape`: If the weight tensor shape is invalid.
/// - `error.InvalidBiasShape`: If the bias tensor shape is invalid.
/// - `error.NegativeVariance`: If the computed variance is negative.
/// - `error.ZeroStandardDeviation`: If the computed standard deviation is zero.
/// - `error.ComputedNaN`: If the computed value is NaN.
/// - `error.ComputedInfinity`: If the computed value is infinity.
///
/// # Stability Checks
///
/// This function performs several stability checks:
/// - Checks the stability of the input, weight, and bias tensors.
/// - Ensures the computed variance is not negative.
/// - Ensures the computed standard deviation is not zero.
/// - Checks for NaN and infinity in the computed values.
/// - Checks the stability of the output tensor before returning it.
///
/// # Example
///
/// ```zig
/// const input = Tensor(f32, .{2, 3}, .{1.0, 2.0, 3.0, 4.0, 5.0, 6.0});
/// const weight = Tensor(f32, .{3}, .{0.1, 0.2, 0.3});
/// const bias = Tensor(f32, .{3}, .{0.0, 0.0, 0.0});
/// const eps = 1e-5;
/// const result = try layerNorm(f32, input, weight, bias, eps);
/// ```
pub fn layerNorm(comptime T: type, input: Tensor(T), weight: Tensor(T), bias: Tensor(T), eps: T) !Tensor(T) {
    // Check input stability
    try checkStability(T, input);
    try checkStability(T, weight);
    try checkStability(T, bias);

    // Validate epsilon
    if (eps <= 0) {
        return error.InvalidEpsilon;
    }

    // Input validation
    if (input.shape.len < 1) {
        return error.InvalidShape;
    }
    const last_dim = input.shape[input.shape.len - 1];

    if (weight.shape.len != 1 or weight.shape[0] != last_dim) {
        return error.InvalidWeightShape;
    }
    if (bias.shape.len != 1 or bias.shape[0] != last_dim) {
        return error.InvalidBiasShape;
    }

    // Calculate size of dimensions before the last dimension
    var leading_dims: usize = 1;
    for (input.shape[0 .. input.shape.len - 1]) |dim| {
        leading_dims *= dim;
    }

    // Create output tensor with same shape as input
    var output = try input.copy();
    errdefer output.deinit();

    // Compute mean and variance for each feature vector
    var i: usize = 0;
    while (i < leading_dims) : (i += 1) {
        const start_idx = i * last_dim;
        const end_idx = start_idx + last_dim;

        // Calculate mean
        var mean: T = 0;
        for (start_idx..end_idx) |j| {
            mean += input.data[j];
        }
        mean /= @as(T, @floatFromInt(last_dim));

        // Calculate variance
        var variance: T = 0;
        for (start_idx..end_idx) |j| {
            const diff = input.data[j] - mean;
            variance += diff * diff;
        }
        variance /= @as(T, @floatFromInt(last_dim));

        // Check for numerical stability in variance
        if (variance < -eps) {
            return error.NegativeVariance;
        }

        // Add stability checks for the normalization process
        const std_dev = @sqrt(variance + eps);
        if (std_dev == 0) {
            return error.ZeroStandardDeviation;
        }

        // Normalize and apply scale and bias
        for (start_idx..end_idx) |j| {
            const feature_idx = j - start_idx;
            const normalized = (input.data[j] - mean) / std_dev;
            const scaled = normalized * weight.data[feature_idx];
            const final_value = scaled + bias.data[feature_idx];

            // Check for stability of computed value
            if (std.math.isNan(final_value)) {
                return error.ComputedNaN;
            }
            if (std.math.isInf(final_value)) {
                return error.ComputedInfinity;
            }

            output.data[j] = final_value;
        }
    }

    // Final stability check on output
    try checkStability(T, output);
    return output;
}

const LayerNormError = error{
    InvalidShape,
    InvalidWeightShape,
    InvalidBiasShape,
    InvalidEpsilon,
    NegativeVariance,
    ZeroStandardDeviation,
    ComputedNaN,
    ComputedInfinity,
} || StabilityError;

/// All possible errors from tensor operations and freqs computation
const FreqsError = error{
    // Tensor initialization errors
    TensorTooLarge,
    IncompatibleShape,

    // Input validation errors
    DimensionTooSmall,
    DimensionNotEven,
    EndTooSmall,
    ThetaTooSmall,
    InvalidShape,

    // Computation errors
    ComputationOverflow,
    NumericalInstability,

    // Memory errors
    OutOfMemory,
};

/// Precomputes frequency values for a given dimension and range, using a specified theta value.
/// This function generates a tensor containing the cosine and sine values of the frequencies.
///
/// # Parameters
/// - `T`: The type of the tensor elements (must be a floating-point type).
/// - `allocator`: The allocator to use for memory allocation.
/// - `dim`: The dimension size (must be a positive even number).
/// - `end`: The end value for the time range (must be a positive number).
/// - `theta`: The theta value used in the frequency computation (must be a positive number).
///
/// # Returns
/// - `Tensor(T)`: A tensor containing the precomputed frequency values.
/// - `FreqsError`: An error if any of the input parameters are invalid or if numerical instability occurs.
///
/// # Errors
/// - `DimensionTooSmall`: If `dim` is less than or equal to 0.
/// - `DimensionNotEven`: If `dim` is not an even number.
/// - `EndTooSmall`: If `end` is less than or equal to 0.
/// - `ThetaTooSmall`: If `theta` is less than or equal to 0.
/// - `ComputationOverflow`: If the computed power value is outside the range [-1000, 1000].
/// - `NumericalInstability`: If any numerical instability is detected during the computation.
///
/// # Example
/// ```zig
/// const std = @import("std");
/// const Tensor = @import("tensor.zig").Tensor;
/// const precomputeFrequencies = @import("ops.zig").precomputeFrequencies;
///
/// const allocator = std.heap.page_allocator;
/// const result = precomputeFrequencies(f32, allocator, 4, 10, 2.0) catch |err| {
///     std.debug.print("Error: {}\n", .{err});
///     return;
/// };
///
/// defer result.deinit();
/// std.debug.print("Result: {}\n", .{result});
/// ```
pub fn precomputeFrequencies(
    comptime T: type,
    allocator: std.mem.Allocator,
    dim: usize,
    end: usize,
    theta: T,
) FreqsError!Tensor(T) {
    // Input validation
    if (dim <= 0) return error.DimensionTooSmall;
    if (dim % 2 != 0) return error.DimensionNotEven;
    if (end <= 0) return error.EndTooSmall;
    if (theta <= 0) return error.ThetaTooSmall;

    // 1. Create initial frequencies
    var freqs = try Tensor(T).init(allocator, &[_]usize{dim / 2});
    errdefer freqs.deinit();

    const dim_float: T = @floatFromInt(dim);
    for (0..dim / 2) |i| {
        const idx_float: T = @floatFromInt(i * 2);
        const power = idx_float / dim_float; // Removed negative sign to match Python

        // Check for potential overflow
        if (power < -1000 or power > 1000) {
            return error.ComputationOverflow;
        }

        const theta_power = std.math.pow(T, theta, power);
        // Check for division by zero or overflow
        if (theta_power == 0 or !std.math.isFinite(theta_power)) {
            return error.NumericalInstability;
        }

        freqs.data[i] = 1.0 / theta_power; // Now matches Python's 1.0 / (theta ** x)

        // Check for numerical stability
        if (!std.math.isFinite(freqs.data[i])) {
            return error.NumericalInstability;
        }
    }

    // 2. Create time tensor [end, 1]
    var time_range = try Tensor(T).init(allocator, &[_]usize{ end, 1 });
    errdefer time_range.deinit();

    for (0..end) |i| {
        time_range.data[i] = @floatFromInt(i);
    }

    // 3. Reshape freqs and prepare for multiplication
    try freqs.reshape(&[_]usize{ 1, dim / 2 });

    // Initialize freq_matrix for the outer product
    var freq_matrix = try Tensor(T).init(allocator, &[_]usize{ end, dim / 2 });
    errdefer freq_matrix.deinit();

    // Perform the outer product (t * freqs)
    for (0..end) |i| {
        for (0..dim / 2) |j| {
            const product = time_range.data[i] * freqs.data[j];
            if (!std.math.isFinite(product)) {
                return error.NumericalInstability;
            }
            freq_matrix.data[i * (dim / 2) + j] = product;
        }
    }

    // 4. Calculate exp(i * freqs) -> [cos(x), sin(x)]
    var result = try Tensor(T).init(allocator, &[_]usize{ end, dim / 2, 2 });
    errdefer result.deinit();

    // Calculate cos and sin values (equivalent to exp(i*x) = cos(x) + i*sin(x))
    for (0..end) |i| {
        for (0..dim / 2) |j| {
            const x = freq_matrix.data[i * (dim / 2) + j];
            const cos_val = @cos(x);
            const sin_val = @sin(x);

            // Check for numerical stability
            if (!std.math.isFinite(cos_val) or !std.math.isFinite(sin_val)) {
                return error.NumericalInstability;
            }

            // Real part (cos)
            result.data[i * (dim / 2) * 2 + j * 2] = cos_val;
            // Imaginary part (sin)
            result.data[i * (dim / 2) * 2 + j * 2 + 1] = sin_val;
        }
    }

    // Cleanup intermediate tensors
    freqs.deinit();
    time_range.deinit();
    freq_matrix.deinit();

    return result;
}

const RotaryError = error{
    InvalidDimension,
    InvalidShape,
    ShapeMismatch,
    InvalidPositionIds,
    DimensionMismatch, // Added for concat
    IncompatibleShapes, // Added for concat
} || FreqsError;

/// Applies rotary position embeddings to the input tensor
///
/// Parameters:
///   comptime T: The type of the tensor elements
///   allocator: The allocator to use for memory allocations
///   x: Input tensor of shape [num_heads, seq_len, head_dim]
///   freqs_cis: Precomputed frequencies of shape [seq_len, rot_dim/2, 2]
///   position_ids: Position indices of shape [seq_len]
///   rot_dim: Dimension to rotate (must be <= head_dim)
///   interleave: Whether complex numbers are stored in interleaved format
///
/// Returns:
///   Tensor with rotary embeddings applied
///
/// Errors:
///   error.InvalidInputDimensions: If the input tensor does not have 3 dimensions
///   error.InvalidRotationDimension: If the rotation dimension does not match the expected size
///
/// Example:
/// ```zig
/// const allocator = std.heap.page_allocator;
/// const x = Tensor(f32).init(allocator, &[_]usize{32, 13, 16});
/// const freqs_cis = Tensor(f32).init(allocator, &[_]usize{13, 8, 2});
/// const position_ids = Tensor(usize).init(allocator, &[_]usize{13});
/// const result = try applyRotaryEmb(f32, allocator, x, freqs_cis, position_ids, 16, true);
/// defer result.deinit();
/// ```
pub fn applyRotaryEmb(
    comptime T: type,
    allocator: Allocator,
    x: Tensor(T),
    freqs_cis: Tensor(T),
    position_ids: Tensor(usize),
    rot_dim: usize,
    interleave: bool,
) !Tensor(T) {
    // Validate input constraints
    if (x.shape.len != 3) {
        return error.InvalidInputDimensions;
    }
    if (rot_dim != freqs_cis.shape[freqs_cis.shape.len - 2] * 2) {
        return error.InvalidRotationDimension;
    }

    const n_heads = x.shape[0]; // 32
    const seq_len = x.shape[1]; // 13
    const head_dim = x.shape[2]; // 16

    // Split x into rotation and pass-through parts
    var x_rot = try x.getSliceRange(&[_]Slice{
        Slice.full(), // Head (32)
        Slice.full(), // Sequence (13)
        Slice.from(0, rot_dim), // First rot_dim features
    });
    defer x_rot.deinit();

    var x_pass = if (rot_dim < head_dim) blk: {
        const pass = try x.getSliceRange(&[_]Slice{
            Slice.full(), // Head (32)
            Slice.full(), // Sequence (13)
            Slice.from(rot_dim, null), // Remaining features
        });
        break :blk pass;
    } else Tensor(T).init(allocator, &[_]usize{ n_heads, seq_len, 0 }) catch unreachable;
    defer x_pass.deinit();

    // x_rot and x_pass are correct!

    // Handle interleaved vs non-interleaved cases
    var xq_r: Tensor(T) = undefined;
    var xq_i: Tensor(T) = undefined;

    if (interleave) {
        // Reshape x_rot to [n_heads, seq_len, rot_dim/2, 2]
        var reshaped = try x_rot.copy();
        defer reshaped.deinit();
        try reshaped.reshape(&[_]usize{ n_heads, seq_len, rot_dim / 2, 2 });

        // Extract real and imaginary parts (n_heads, seq_len, rot_dim/2)
        xq_r = try reshaped.getSliceRange(&[_]Slice{
            Slice.full(),
            Slice.full(),
            Slice.full(),
            Slice.from(0, 1),
        });
        try xq_r.reshape(&[_]usize{ n_heads, seq_len, rot_dim / 2 });

        xq_i = try reshaped.getSliceRange(&[_]Slice{
            Slice.full(),
            Slice.full(),
            Slice.full(),
            Slice.from(1, 2),
        });
        try xq_i.reshape(&[_]usize{ n_heads, seq_len, rot_dim / 2 });
    } else {
        // Split last dimension in half
        xq_r = try x_rot.getSliceRange(&[_]Slice{
            Slice.full(),
            Slice.full(),
            Slice.from(0, rot_dim / 2),
        });
        xq_i = try x_rot.getSliceRange(&[_]Slice{
            Slice.full(),
            Slice.full(),
            Slice.from(rot_dim / 2, null),
        });
    }

    // xq_r and xq_i are correct!
    defer xq_r.deinit();
    defer xq_i.deinit();

    // Get cos and sin from freqs_cis
    var cos_part = try freqs_cis.getSliceRange(&[_]Slice{
        Slice.full(),
        Slice.full(),
        Slice.from(0, 1),
    });
    defer cos_part.deinit();

    var sin_part = try freqs_cis.getSliceRange(&[_]Slice{
        Slice.full(),
        Slice.full(),
        Slice.from(1, 2),
    });
    defer sin_part.deinit();

    // Create freqs_cos and freqs_sin with shape (1, seq_len, rot_dim/2)
    var freqs_cos = try zeros(T, allocator, &[_]usize{
        1,
        seq_len,
        rot_dim / 2,
    });
    defer freqs_cos.deinit();

    var freqs_sin = try zeros(T, allocator, &[_]usize{
        1,
        seq_len,
        rot_dim / 2,
    });
    defer freqs_sin.deinit();

    // Fill freqs_cos and freqs_sin using position_ids
    for (0..seq_len) |i| {
        const pos_id = position_ids.data[i];
        const offset = i * (rot_dim / 2);
        @memcpy(freqs_cos.data[offset .. offset + rot_dim / 2], cos_part.data[pos_id * cos_part.shape[1] .. (pos_id + 1) * cos_part.shape[1]]);
        @memcpy(freqs_sin.data[offset .. offset + rot_dim / 2], sin_part.data[pos_id * sin_part.shape[1] .. (pos_id + 1) * sin_part.shape[1]]);
    }

    // freqs sin and cos are correct!

    // Complex multiply with broadcasting across heads
    // (a + bi)(c + di) = (ac - bd) + (ad + bc)i
    var xq_out_r = try xq_r.copy(); // Will be (n_heads, seq_len, rot_dim/2)
    defer xq_out_r.deinit();
    try broadcast_multiply(T, &xq_out_r, freqs_cos);

    var temp = try xq_i.copy();
    defer temp.deinit();
    try broadcast_multiply(T, &temp, freqs_sin);
    try broadcast_subtract(T, &xq_out_r, temp);

    var xq_out_i = try xq_r.copy(); // Will be (n_heads, seq_len, rot_dim/2)
    defer xq_out_i.deinit();
    try broadcast_multiply(T, &xq_out_i, freqs_sin);

    var temp2 = try xq_i.copy();
    defer temp2.deinit();
    try broadcast_multiply(T, &temp2, freqs_cos);
    try broadcast_add(T, &xq_out_i, temp2);

    // xq_out_r amd xq_out_i are correct!

    // Stack real and imaginary parts -> (n_heads, seq_len, rot_dim)
    var tensors = [_]Tensor(T){ xq_out_r, xq_out_i };
    var stacked = try stack(T, &tensors, 3);
    defer stacked.deinit();

    try flatten(f32, &stacked, 2, 3);

    // stacked.print3D();

    // std.debug.print("stacked shape (xq_out) {any} \n", .{stacked.shape});
    // std.debug.print("x_pass shape {any} \n", .{x_pass.shape});

    // Concatenate with pass-through
    if (x_pass.data.len > 0) {
        return concat(T, stacked, x_pass, 2);
    } else {
        return stacked.copy();
    }
}

/// Create an attention mask for proper causal attention alignment.
///
/// This function generates a mask tensor of shape `[1, seq_len, pos + seq_len]`
/// where the first `pos` elements in each row are set to `true`, and the remaining
/// elements form a lower triangular matrix. This ensures that each position can
/// only attend to previous positions and itself, which is essential for causal
/// attention mechanisms in sequence models.
///
/// # Parameters
/// - `allocator`: The allocator to use for memory allocation.
/// - `pos`: The position offset for the mask.
/// - `seq_len`: The length of the sequence.
///
/// # Returns
/// - `Tensor(bool)`: A tensor of shape `[1, seq_len, pos + seq_len]` representing
///   the attention mask.
///
/// # Errors
/// - Returns an error if memory allocation fails.
///
/// # Example
/// ```zig
/// const allocator = std.heap.page_allocator;
/// const mask = try createAttentionMask(allocator, 5, 10);
/// defer mask.deinit();
/// ```
// Create attention mask for proper causal attention alignment
pub fn createAttentionMask(allocator: Allocator, pos: usize, seq_len: usize) !Tensor(bool) {
    // First create the base mask of shape [seq_len, pos + seq_len]
    var mask = try Tensor(bool).init(allocator, &[_]usize{ seq_len, pos + seq_len });
    errdefer mask.deinit();

    // Fill the first part (before pos) with true
    for (0..seq_len) |i| {
        for (0..pos) |j| {
            const idx = i * (pos + seq_len) + j;
            mask.data[idx] = true;
        }
    }

    // Fill the second part (pos onwards) with lower triangular matrix
    for (0..seq_len) |i| {
        for (0..seq_len) |j| {
            const idx = i * (pos + seq_len) + (j + pos);
            mask.data[idx] = j <= i; // Lower triangular
        }
    }

    // Reshape to add head dimension [1, seq_len, pos + seq_len]
    try mask.reshape(&[_]usize{ 1, seq_len, pos + seq_len });

    return mask;
}

/// Scaled Dot Product Attention with mask
///
/// This function computes the scaled dot product attention for a given set of query, key, and value tensors,
/// applying a mask to the attention scores. The attention mechanism is computed separately for each attention head.
///
/// Parameters:
/// - `T`: The data type of the tensor elements (e.g., `f32` or `f64`).
/// - `query`: The query tensor with shape `[n_heads, q_len, head_dim]`.
/// - `key`: The key tensor with shape `[n_heads, kv_len, head_dim]`.
/// - `value`: The value tensor with shape `[n_heads, kv_len, head_dim]`.
/// - `mask`: The attention mask tensor with shape `[n_heads, q_len, kv_len]`, where `true` indicates valid positions and `false` indicates masked positions.
/// - `allocator`: The allocator to use for memory allocations.
///
/// Returns:
/// - A tensor of shape `[n_heads, q_len, head_dim]` containing the result of the scaled dot product attention.
///
/// Errors:
/// - Returns an error if any memory allocation fails or if tensor operations fail.
///
/// Example:
/// ```zig
/// const T = f32;
/// const query = try Tensor(T).init(allocator, &[_]usize{n_heads, q_len, head_dim});
/// const key = try Tensor(T).init(allocator, &[_]usize{n_heads, kv_len, head_dim});
/// const value = try Tensor(T).init(allocator, &[_]usize{n_heads, kv_len, head_dim});
/// const mask = try Tensor(bool).init(allocator, &[_]usize{n_heads, q_len, kv_len});
/// defer {
///     query.deinit();
///     key.deinit();
///     value.deinit();
///     mask.deinit();
/// }
/// const result = try scaledDotProductAttention(T, query, key, value, mask, allocator);
/// defer result.deinit();
/// ```
// Scaled Dot Product Attention with mask
pub fn scaledDotProductAttention(
    comptime T: type,
    query: Tensor(T),
    key: Tensor(T),
    value: Tensor(T),
    mask: Tensor(bool),
    allocator: Allocator,
) !Tensor(T) {
    const n_heads = query.shape[0];
    const q_len = query.shape[1];
    const kv_len = key.shape[1];
    const head_dim = query.shape[2];

    // Scale factor for attention scores
    const scale: T = 1.0 / @sqrt(@as(T, @floatFromInt(head_dim)));

    // Initialize output tensor
    var out = try Tensor(T).init(allocator, &[_]usize{ n_heads, q_len, head_dim });
    errdefer out.deinit();

    // Prepare transposed key for all heads
    var key_transpose = try key.copy();
    defer key_transpose.deinit();
    try transposeAxes(T, &key_transpose, 1, 2);

    // Process each attention head separately
    for (0..n_heads) |h| {
        // Get the query, key, value slices for this head
        var query_head = try query.getDimensionSlice(0, h);
        defer query_head.deinit();

        var key_head = try key_transpose.getDimensionSlice(0, h);
        defer key_head.deinit();

        var value_head = try value.getDimensionSlice(0, h);
        defer value_head.deinit();

        // Calculate attention scores for this head
        var attn_weights_flat = try simdmatmul.matmul(T, query_head, key_head, allocator);
        defer attn_weights_flat.deinit();

        // Apply scaling factor
        scalarMultiply(T, &attn_weights_flat, scale);

        // Apply attention mask - fixed version with proper 2D indexing
        // The mask has shape [seq_len, pos + seq_len] where pos is the current position
        for (0..q_len) |q| {
            for (0..kv_len) |k| {
                // Direct 2D indexing into the mask
                const mask_index = q * (mask.shape[2]) + k;
                const flat_index = q * kv_len + k;

                // Apply negative infinity masking where mask is false
                if (!mask.data[mask_index]) {
                    attn_weights_flat.data[flat_index] = -std.math.inf(T);
                }
            }
        }

        // Apply softmax to get attention probabilities
        try softmax(T, &attn_weights_flat, 1);

        // Calculate weighted sum with values
        var out_flat = try simdmatmul.matmul(T, attn_weights_flat, value_head, allocator);
        defer out_flat.deinit();

        // Copy results to output tensor for this head
        for (0..q_len) |q| {
            for (0..head_dim) |d| {
                const out_idx = h * q_len * head_dim + q * head_dim + d;
                const flat_idx = q * head_dim + d;
                out.data[out_idx] = out_flat.data[flat_idx];
            }
        }
    }

    return out;
}

// Softmax operation along specified dimension
fn softmax(comptime T: type, tensor: *Tensor(T), dim: usize) !void {
    const dim_size = tensor.shape[dim];

    // Calculate stride for the specified dimension
    var stride: usize = 1;
    for (dim + 1..tensor.shape.len) |i| {
        stride *= tensor.shape[i];
    }

    // Calculate number of vectors to process
    var num_vectors: usize = 1;
    for (0..dim) |i| {
        num_vectors *= tensor.shape[i];
    }

    // Process each vector
    for (0..num_vectors) |i| {
        const base_idx = i * dim_size * stride;

        // Find max for numerical stability
        var max: T = -std.math.inf(T);
        for (0..dim_size) |j| {
            const val = tensor.data[base_idx + j * stride];
            if (val > max) max = val;
        }

        // Calculate exp and sum
        var sum: T = 0;
        for (0..dim_size) |j| {
            const idx = base_idx + j * stride;
            tensor.data[idx] = @exp(tensor.data[idx] - max);
            sum += tensor.data[idx];
        }

        // Normalize
        if (sum > 0) {
            for (0..dim_size) |j| {
                const idx = base_idx + j * stride;
                tensor.data[idx] /= sum;
            }
        }
    }
}

pub fn gelu(comptime T: type, tensor: *Tensor(T)) !void {
    if (@typeInfo(T) != .Float) {
        @compileError("GELU operation requires floating-point tensor");
    }

    // Constants for GELU approximation
    const sqrt_2_div_pi: T = @sqrt(2.0 / std.math.pi);
    const alpha: T = 0.044715;

    for (tensor.data) |*x| {
        const val = x.*;
        const x_cubed = val * val * val;
        const inner = sqrt_2_div_pi * (val + alpha * x_cubed);
        x.* = 0.5 * val * (1 + std.math.tanh(inner));
    }
}

pub fn argmax(comptime T: type, input: Tensor(T)) !usize {
    if (input.data.len == 0 or input.shape.len == 0) {
        return error.EmptyTensor;
    }

    // Get the last dimension size for vocab
    const vocab_size = input.shape[input.shape.len - 1];

    // For logits, we only care about the last value since we're doing token generation
    const start_idx = input.data.len - vocab_size;

    var max_value: T = input.data[start_idx];
    var max_index: usize = 0;

    // Find the maximum value and its index
    for (start_idx..input.data.len) |i| {
        if (input.data[i] > max_value) {
            max_value = input.data[i];
            max_index = i - start_idx;
        }
    }

    return max_index;
}
