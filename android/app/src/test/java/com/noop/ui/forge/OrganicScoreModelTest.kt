package com.noop.ui.forge

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The port must draw the iOS ring, so its numbers are pinned to the Swift `OrganicScoreVisualModel` and
 * `OrganicScorePreparation`: the expected values below are what Swift printed for the same inputs (time 1.5 s,
 * full quality, still motion).
 */
class OrganicScoreModelTest {
    private data class Case(val metric: OrganicMetric, val value: Double, val unit: Double, val radius: Double,
                            val filament: Double, val particles: Int, val strands: Int, val px: Double, val py: Double)

    private val swift = listOf(
        Case(OrganicMetric.Charge, 72.0, 0.4429871815912615, 1.024220682840311, 0.9524031936030469, 152, 6,
             0.9201071929660627, -0.2582092138130751),
        Case(OrganicMetric.Effort, 41.0, 0.07564677726830238, 1.0068459490422446, 0.9417389404168873, 68, 4,
             0.5840083707216511, -0.8062388937045167),
        Case(OrganicMetric.Rest, 92.0, 0.6237888193806383, 0.9531401705289768, 0.8854253304514534, 250, 8,
             0.8506706181790473, 0.00839600414183196),
    )

    @Test fun theGeometryMatchesTheSwiftModel() {
        for (c in swift) {
            val model = OrganicScoreModel.resolve(c.metric, c.value)
            val frame = OrganicPreparation(model).frame(1.5)
            assertEquals(c.metric.name, c.unit, model.particleUnit(3, 7), 1e-15)
            assertEquals(c.metric.name, c.radius, frame.contourRadius(0.3), 1e-12)
            assertEquals(c.metric.name, c.filament,
                         frame.filamentRadius(1, model.filamentCount(), 1.1, frame.filamentFrame(1)), 1e-12)
            assertEquals(c.metric.name, c.particles, model.particleCount())
            assertEquals(c.metric.name, c.strands, model.filamentCount())
            val p = frame.particle(5)!!
            assertEquals(c.metric.name, c.px, p.x, 1e-12)
            assertEquals(c.metric.name, c.py, p.y, 1e-12)
        }
    }

    @Test fun aMissingScoreIsQuietAndEffortWaits() {
        val effort = OrganicScoreModel.resolve(OrganicMetric.Effort, null)
        assertEquals(true, effort.awaitsEffort)
        assertEquals(0, effort.particleCount())
        assertEquals(1, OrganicScoreModel.resolve(OrganicMetric.Rest, null).filamentCount())
    }
}
