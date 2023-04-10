﻿/**
Module contains optical flow pyramid implementation.

Pyramidal optical flow evaluation in $(BIG DCV) is designed to be a wrapper to actual optical flow algorithm. $(LINK2 #SparesePyramidFlow, Sparse) and 
$(LINK2 #DensePyramidFlow, dense) optical flow algorithms have a corresponding utility class which will evaluate the algorithm 
in $(LINK3 https://en.wikipedia.org/wiki/Pyramid_(image_processing)#Gaussian_pyramid, pyramid), coarse-to-fine fashion.

----
// Evaluate Horn-Schunck method in pyramid.
HornSchunckFlow hsFlow = new HornSchunckFlow(props);
DensePyramidFlow densePyramid = new DensePyramidFlow(hsFlow, pyramidLevels); 

auto flow = densePyramid.evaluate(current, next);
----

Copyright: Copyright Relja Ljubobratovic 2016.

Authors: Relja Ljubobratovic

License: $(LINK3 http://www.boost.org/LICENSE_1_0.txt, Boost Software License - Version 1.0).
*/
module dcv.tracking.opticalflow.pyramidflow;

import std.array : staticArray;
import mir.algorithm.iteration: each;

import dcv.core.utils : emptyRCSlice;
import dcv.core.image;
import dcv.imgproc.imgmanip : warp, resize;
import dcv.tracking.opticalflow.base;

import mir.ndslice.allocation;
import mir.ndslice.topology: as, flattened, iota, reshape;
import mir.rc;
import mir.exception;

import dplug.core.nogc;
/**
Sparse pyramidal optical flow utility class.
*/
class SparsePyramidFlow : SparseOpticalFlow
{

    private SparseOpticalFlow flowAlgorithm;
    private uint levelCount;

    @nogc nothrow:

    this(SparseOpticalFlow flow, uint levels)
    in
    {
        assert(flow !is null);
        assert(levels > 0);
    }
    do
    {
        flowAlgorithm = flow;
        levelCount = levels;
    }

    override Slice!(RCI!(float[2]), 1) evaluate(Image f1, Image f2, float[2][] points,
            float[2][] searchRegions, Slice!(RCI!(float[2]), 1) flow = emptyRCSlice!(1, float[2]), bool usePrevious = false)
    in
    {
        assert(!f1.empty && !f2.empty && f1.size == f2.size && f1.channels == 1 && f1.depth == f2.depth);
        assert(points.length == searchRegions.length);
        if (usePrevious)
        {
            assert(!flow.empty);
            assert(points.length == flow.length);
        }
    }
    do
    {
        import mir.ndslice.slice: sliced;

        size_t[2] size = [f1.height, f1.width];
        const auto pointCount = points.length;

        // pyramid flow array - each item is double sized flow from the next
        size_t[2][] flowPyramid = mallocSlice!(size_t[2])(levelCount);
        scope(exit) freeSlice(flowPyramid);

        flowPyramid[$ - 1] = size;

        foreach_reverse (i; 0 .. (levelCount - 1))
        {
            size[] /= 2;
            if (size[0] < 1 || size[1] < 1){
                try enforce!"Pyramid downsampling exceeded minimal image size."(false);
                catch(Exception e) assert(false, e.msg);
            }
            flowPyramid[i] = size;
        }

        float[2] flowScale = [cast(float)f1.height / cast(float)flowPyramid[0][0],
            cast(float)f1.width / cast(float)flowPyramid[0][1]];

        float[2][] lpoints = mallocSlice!(float[2])(points.length); lpoints[] = points[]; // dup here
        scope(exit) freeSlice(lpoints);
        
        float[2][] lsearchRegions = mallocSlice!(float[2])(searchRegions.length); lsearchRegions[] = searchRegions[]; // dup here
        scope(exit) freeSlice(lsearchRegions);

        alias scale = (ref v) { v[0] /= flowScale[0]; v[1] /= flowScale[1]; };
        lpoints.sliced(lpoints.length).each!scale;
        lsearchRegions.sliced(lsearchRegions.length).each!scale;

        if (usePrevious)
        {
            flow.each!scale;
        }
        else
        {
            flow = uninitRCslice!(float[2])(pointCount);
            flow[] = [0.0f, 0.0f].staticArray;
        }

        auto h = f1.height;
        auto w = f1.width;

        Slice!(RCI!float, 2LU, SliceKind.contiguous) current, next, f1s, f2s;
        switch (f1.depth) 
        {
            case BitDepth.BD_32:
                f1s = f1.sliced.as!float.flattened.sliced(f1.height, f1.width).rcslice;
                f2s = f2.sliced.as!float.flattened.sliced(f2.height, f2.width).rcslice;
                break;
            case BitDepth.BD_16:
                f1s = f1.sliced.as!ushort.flattened.sliced(f1.height, f1.width).as!float.rcslice;
                f2s = f2.sliced.as!ushort.flattened.sliced(f2.height, f2.width).as!float.rcslice;
                break;
            default:
                f1s = f1.sliced.as!ubyte.flattened.sliced(f1.height, f1.width).as!float.rcslice;
                f2s = f2.sliced.as!ubyte.flattened.sliced(f2.height, f2.width).as!float.rcslice;
        }

        // calculate pyramid flow
        foreach (i; 0 .. levelCount)
        {

            auto lh = flowPyramid[i][0];
            auto lw = flowPyramid[i][1];

            if (lh != h || lw != w)
            {
                current = f1s.lightScope.resize([lh, lw]);
                next = f2s.lightScope.resize([lh, lw]);
            }
            else
            {
                current = f1s;
                next = f2s;
            }

            auto n_im = next.asImage(f2.format);
            scope(exit) destroyFree(n_im);

            auto inim = current.asImage(f1.format);
            scope(exit) destroyFree(inim);

            flowAlgorithm.evaluate(inim, n_im, lpoints,
                    lsearchRegions, flow, true);

            if (i < levelCount - 1)
            {
                alias twice = (ref v) { v[0] += v[0]; v[1] += v[1]; };
                flow.each!twice;
                lpoints.sliced(lpoints.length).each!twice;
                lsearchRegions.sliced(lsearchRegions.length).each!twice;
            }
        }

        return flow;
    }
}

/**
Dense pyramidal optical flow utility class.
*/
class DensePyramidFlow : DenseOpticalFlow
{

    private DenseOpticalFlow flowAlgorithm;
    private uint levelCount;

    @nogc nothrow:

    this(DenseOpticalFlow flow, uint levels)
    in
    {
        assert(flow !is null);
        assert(levels > 0);
    }
    do
    {
        flowAlgorithm = flow;
        levelCount = levels;
    }

    override DenseFlow evaluate(Image f1, Image f2, DenseFlow prealloc = emptyRCSlice!(3,
            float), bool usePrevious = false)
    in
    {
        assert(prealloc.length!2 == 2);
        assert(!f1.empty && f1.size == f2.size && f1.depth == f2.depth && f1.depth == BitDepth.BD_8);
        if (usePrevious)
        {
            assert(prealloc.length!0 == f1.height && prealloc.length!1 == f1.width);
        }
    }
    do
    {
        import mir.ndslice.slice: sliced;
        
        size_t[2] size = [f1.height, f1.width];
        uint level = 0;

        // pyramid flow array - each item is double sized flow from the next
        size_t[2][] flowPyramid = mallocSlice!(size_t[2])(levelCount);
        scope(exit) freeSlice(flowPyramid);

        flowPyramid[$ - 1] = size;

        DenseFlow flow;

        foreach_reverse (i; 0 .. (levelCount - 1))
        {
            size[] /= 2;
            if (size[0] < 1 || size[1] < 1){
                try enforce!"Pyramid downsampling exceeded minimal image size"(false);
                catch(Exception e) assert(false, e.msg);
            }
            flowPyramid[i] = size;
        }

        // allocate flow for each pyramid level
        if (usePrevious)
        {
            flow = prealloc.lightScope.resize(flowPyramid[0]);
        }
        else
        {
            int err;
            flow = RCArray!float(flowPyramid[0][0] * flowPyramid[0][1] * 2)
                .moveToSlice.reshape([flowPyramid[0][0], flowPyramid[0][1], 2], err);
            flow[] = 0.0f;
        }

        auto h = f1.height;
        auto w = f1.width;

        Slice!(RCI!float, 2LU, SliceKind.contiguous) current, next, corig, norig;
        switch (f1.depth) 
        {
            case BitDepth.BD_32:
                corig = f1.sliced.as!float.flattened.sliced(f1.height, f1.width).rcslice;
                norig = f2.sliced.as!float.flattened.sliced(f2.height, f2.width).rcslice;
                break;
            case BitDepth.BD_16:
                corig = f1.sliced.as!ushort.flattened.sliced(f1.height, f1.width).as!float.rcslice;
                norig = f2.sliced.as!ushort.flattened.sliced(f2.height, f2.width).as!float.rcslice;
                break;
            default:
                corig = f1.sliced.flattened.sliced(f1.height, f1.width).as!float.rcslice;
                norig = f2.sliced.flattened.sliced(f2.height, f2.width).as!float.rcslice;
        }

        // first flow used as indicator to skip the first warp.
        bool firstFlow = usePrevious;

        // calculate pyramid flow
        foreach (i; 0 .. levelCount)
        {
            auto lh = flow.length!0;
            auto lw = flow.length!1;

            if (lh != h || lw != w)
            {
                current = corig.lightScope.resize([lh, lw]);
                next = norig.lightScope.resize([lh, lw]);
            }
            else
            {
                current = corig;
                next = norig;
            }

            if (!firstFlow)
            {
                // warp the image using previous flow, 
                // except if this is the first level
                // or usePrevious is false.
                current = warp(current, flow);
            }

            auto curim = current.asImage(f1.format);
            scope(exit) destroyFree(curim);

            auto nextim = next.asImage(f2.format);
            scope(exit) destroyFree(nextim);

            // evaluate the flow algorithm
            auto lflow = flowAlgorithm.evaluate(curim, nextim);

            // add flow calculated in this iteration to previous one.
            flow[] += lflow;

            if (i < levelCount - 1)
            {
                flow = flow.lightScope.resize(flowPyramid[i + 1]);
                flow[] *= 2.0f;
            }
            // assign the first flow indicator to false.
            firstFlow = false;
        }

        return flow;
    }

}

// TODO: implement functional tests.
version (unittest)
{

    import std.algorithm.iteration : map;
    import std.array : array;
    import std.random : uniform;
    import mir.ndslice.slice;

    private auto createImage()
    {
        return new Image(32, 32, ImageFormat.IF_MONO, BitDepth.BD_8, (32 * 32)
                .iota.map!(v => cast(ubyte)uniform(0, 255)).array);
    }

    class DummySparseFlow : SparseOpticalFlow
    {
        override Slice!(RCI!(float[2]), 1) evaluate(Image f1, Image f2, in float[2][],
                in float[2][] searchRegions, Slice!(RCI!(float[2]), 1) prevflow = null, bool usePrevious = false)
        {
            import std.array : uninitializedArray;

            return uninitRCslice!(float[2])(points.length);
        }
    }

    class DummyDenseFlow : DenseOpticalFlow
    {
        override DenseFlow evaluate(Image f1, Image f2, DenseFlow prealloc = emptyRCSlice!(3,
                float), bool usePrevious = false)
        {
            return RCArray!float(f1.height * f1.width * 2).sliced(f1.height, f1.width, 2);
        }
    }
}

unittest
{
    SparsePyramidFlow flow = new SparsePyramidFlow(new DummySparseFlow, 3);
    auto f1 = createImage();
    auto f2 = createImage();
    auto p = 10.iota.map!(v => cast(float[2])[cast(float)uniform(0, 2), cast(float)uniform(0, 2)]).array;
    auto r = 10.iota.map!(v => cast(float[2])[3.0f, 3.0f]).array;
    auto f = flow.evaluate(f1, f2, p, r);
    assert(f.length == p.length);
}

unittest
{
    DensePyramidFlow flow = new DensePyramidFlow(new DummyDenseFlow, 3);
    auto f1 = createImage();
    auto f2 = createImage();
    auto f = flow.evaluate(f1, f2);
    assert(f.length!0 == f1.height && f.length!1 == f1.width && f.length!2 == 2);
}
