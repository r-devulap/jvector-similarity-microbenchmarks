package io.github.raghuveer.jvecsim;

import io.github.jbellis.jvector.vector.VectorizationProvider;
import io.github.jbellis.jvector.vector.VectorUtil;
import io.github.jbellis.jvector.vector.types.VectorFloat;
import io.github.jbellis.jvector.vector.types.VectorTypeSupport;
import org.openjdk.jmh.annotations.Benchmark;
import org.openjdk.jmh.annotations.BenchmarkMode;
import org.openjdk.jmh.annotations.Fork;
import org.openjdk.jmh.annotations.Measurement;
import org.openjdk.jmh.annotations.Mode;
import org.openjdk.jmh.annotations.OutputTimeUnit;
import org.openjdk.jmh.annotations.Param;
import org.openjdk.jmh.annotations.Scope;
import org.openjdk.jmh.annotations.Setup;
import org.openjdk.jmh.annotations.State;
import org.openjdk.jmh.annotations.Warmup;
import org.openjdk.jmh.infra.Blackhole;

import java.util.Random;
import java.util.concurrent.TimeUnit;

/**
 * JMH microbenchmark for jvector VectorUtil similarity functions.
 *
 * <p>Measures {@code cosine}, {@code dotProduct}, and {@code squareL2Distance}
 * across vector dimensions 64, 128, 512, 768, and 1024.
 *
 * <h2>Backend selection</h2>
 * jvector's {@link VectorizationProvider} is a JVM-lifetime singleton, so each
 * backend must run in its own JVM process.  {@code run_benchmarks.sh} handles
 * this: it launches a separate {@code java … -jar benchmarks.jar} invocation
 * per backend, passing the appropriate JVM flags and pinning {@code -p backend=}
 * so the label appears in every result row.
 *
 * <table>
 *   <tr><th>backend param</th><th>JVM flags used by the script</th><th>Provider loaded</th></tr>
 *   <tr><td>scalar</td>
 *       <td><em>(none)</em></td>
 *       <td>DefaultVectorizationProvider (plain Java loops)</td></tr>
 *   <tr><td>panama</td>
 *       <td>{@code --add-modules=jdk.incubator.vector}</td>
 *       <td>PanamaVectorizationProvider (Panama Vector API, SIMD via JIT)</td></tr>
 *   <tr><td>native</td>
 *       <td>{@code --add-modules=jdk.incubator.vector --enable-native-access=ALL-UNNAMED
 *            -Djvector.enable_native_vectorization=true}</td>
 *       <td>NativeVectorizationProvider (Google Highway via JNI)</td></tr>
 * </table>
 */
@BenchmarkMode(Mode.AverageTime)
@OutputTimeUnit(TimeUnit.NANOSECONDS)
@State(Scope.Thread)
@Warmup(iterations = 3, time = 1, timeUnit = TimeUnit.SECONDS)
@Measurement(iterations = 5, time = 1, timeUnit = TimeUnit.SECONDS)
@Fork(1)
public class VectorSimilarityBenchmark {

    /**
     * Label-only param: identifies which backend is active in result output.
     * The actual backend is determined by the JVM flags passed at launch time
     * (see {@code run_benchmarks.sh}).  A mismatch between this param and the
     * flags in use causes {@link #setup()} to throw immediately.
     */
    @Param({"panama", "native"})
    public String backend;

    @Param({"64", "128", "512", "768", "1024"})
    public int dims;

    private VectorFloat<?> a;
    private VectorFloat<?> b;

    @Setup
    public void setup() {
        // Sanity-check: confirm the provider that actually loaded matches the label.
        // This catches accidental mismatches when running benchmarks manually.
        String providerClass = VectorizationProvider.getInstance().getClass().getSimpleName();
        boolean ok = switch (backend) {
            case "panama" -> providerClass.equals("PanamaVectorizationProvider");
            case "native" -> providerClass.equals("NativeVectorizationProvider");
            default       -> throw new IllegalArgumentException("Unknown backend: " + backend);
        };
        if (!ok) {
            throw new IllegalStateException(
                    "backend param is \"" + backend + "\" but the loaded provider is " +
                    providerClass + ". " +
                    "Pass the correct JVM flags for this backend (see run_benchmarks.sh).");
        }

        VectorTypeSupport vts = VectorizationProvider.getInstance().getVectorTypeSupport();
        Random rng = new Random(42);

        float[] fa = new float[dims];
        float[] fb = new float[dims];
        for (int i = 0; i < dims; i++) {
            fa[i] = rng.nextFloat() * 2 - 1f;
            fb[i] = rng.nextFloat() * 2 - 1f;
        }

        a = vts.createFloatVector(fa);
        b = vts.createFloatVector(fb);
    }

    @Benchmark
    public void cosine(Blackhole bh) {
        bh.consume(VectorUtil.cosine(a, b));
    }

    @Benchmark
    public void dotProduct(Blackhole bh) {
        bh.consume(VectorUtil.dotProduct(a, b));
    }

    @Benchmark
    public void squareL2Distance(Blackhole bh) {
        bh.consume(VectorUtil.squareL2Distance(a, b));
    }
}
