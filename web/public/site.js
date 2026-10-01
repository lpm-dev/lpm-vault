"use strict"

// Must match the flight media query in style.css.
const FLIGHT_QUERY = "(prefers-reduced-motion: no-preference) and (min-width: 1212px)"
const FLIGHT_SCROLL_DISTANCE = 420
const FLOAT_PAUSE_PROGRESS = 0.02
const LANDED_PROGRESS = 0.96

setUpHeroFlight()

function setUpHeroFlight() {
	const hero = document.querySelector("[data-hero]")
	const app = hero?.querySelector("[data-app]")
	if (!hero || !app) return

	const flyers = []
	for (const move of hero.querySelectorAll("[data-flyer]")) {
		const index = Number(move.dataset.flyer)
		const target = hero.querySelector(`[data-flyer-target="${index}"]`)
		const chip = move.firstElementChild
		if (!target || !chip) continue
		flyers.push({
			index,
			move,
			chip,
			target,
			float: move.parentElement,
			tilt: Number.parseFloat(getComputedStyle(move.parentElement).getPropertyValue("--tilt")) || 0,
			bob: 0,
			geometry: null,
		})
	}
	if (flyers.length === 0) return

	const flightMedia = matchMedia(FLIGHT_QUERY)
	const finePointer = matchMedia("(pointer: fine)")
	const resizeObserver = new ResizeObserver(() => remeasure())

	let active = false
	let layout = null
	let frame = 0
	let floating = true
	let pointerX = 0
	let pointerY = 0
	let lastProgress = -1
	let lastPointerX = 0
	let lastPointerY = 0

	flightMedia.addEventListener("change", sync)
	sync()

	function sync() {
		if (flightMedia.matches === active) return
		active = flightMedia.matches
		if (active) {
			addEventListener("scroll", schedule, { passive: true })
			addEventListener("pointermove", onPointerMove, { passive: true })
			resizeObserver.observe(hero)
			document.fonts?.ready.then(remeasure)
		} else {
			removeEventListener("scroll", schedule)
			removeEventListener("pointermove", onPointerMove)
			resizeObserver.disconnect()
			cancelAnimationFrame(frame)
			frame = 0
			reset()
		}
	}

	function remeasure() {
		if (!active) return
		layout = measure()
		lastProgress = -1
		schedule()
	}

	function measure() {
		const appOffset = offsetWithin(app, hero)
		if (!appOffset) return null
		const appWidth = app.offsetWidth
		for (const flyer of flyers) {
			const moveOffset = offsetWithin(flyer.move, hero)
			const targetOffset = offsetWithin(flyer.target, app)
			if (!moveOffset || !targetOffset) return null
			flyer.geometry = {
				centerX: moveOffset.x + flyer.move.offsetWidth / 2,
				centerY: moveOffset.y + flyer.move.offsetHeight / 2,
				height: flyer.move.offsetHeight,
				targetX: targetOffset.x + flyer.target.offsetWidth / 2,
				targetY: targetOffset.y + flyer.target.offsetHeight / 2,
				targetHeight: flyer.target.offsetHeight,
			}
		}
		return { appX: appOffset.x, appY: appOffset.y, appWidth }
	}

	function onPointerMove(event) {
		if (!finePointer.matches) return
		pointerX = event.clientX / innerWidth - 0.5
		pointerY = event.clientY / innerHeight - 0.5
		schedule()
	}

	function schedule() {
		if (!frame) frame = requestAnimationFrame(render)
	}

	function render() {
		frame = 0
		if (!layout) return

		const linear = Math.min(1, Math.max(0, scrollY / FLIGHT_SCROLL_DISTANCE))
		const progress = linear * linear * (3 - 2 * linear)
		const parallax = finePointer.matches ? 1 - progress : 0
		const pointerMoved = pointerX !== lastPointerX || pointerY !== lastPointerY
		if (progress === lastProgress && (parallax === 0 || !pointerMoved)) return
		lastProgress = progress
		lastPointerX = pointerX
		lastPointerY = pointerY

		const scale = 0.95 + 0.05 * progress
		const drop = (1 - progress) * 28
		app.style.transform = `translateY(${drop}px) scale(${scale})`

		const shouldFloat = progress <= FLOAT_PAUSE_PROGRESS
		if (shouldFloat !== floating) {
			floating = shouldFloat
			for (const flyer of flyers) {
				flyer.float.style.animationPlayState = floating ? "" : "paused"
				flyer.bob = floating ? 0 : currentTranslateY(flyer.float)
			}
		}

		const chipOpacity = progress < 0.82 ? "" : String(Math.max(0, 1 - (progress - 0.82) / 0.14))
		const targetOpacity = String(Math.max(0.12, (progress - 0.75) / 0.25))
		const appCenterX = layout.appX + layout.appWidth / 2

		for (const flyer of flyers) {
			const geometry = flyer.geometry
			const landingX = appCenterX + (geometry.targetX - layout.appWidth / 2) * scale
			const landingY = layout.appY + drop + geometry.targetY * scale
			const offsetX = (landingX - geometry.centerX) * progress + pointerX * (12 + flyer.index * 5) * parallax
			const offsetY = (landingY - geometry.centerY - flyer.bob) * progress + pointerY * (10 + flyer.index * 4) * parallax
			const size = 1 + ((geometry.targetHeight * scale) / geometry.height - 1) * progress

			flyer.move.style.transform = `translate(${offsetX}px, ${offsetY}px) scale(${size})`
			flyer.move.style.opacity = chipOpacity
			flyer.chip.style.transform = `rotate(${(1 - progress) * flyer.tilt}deg)`
			flyer.chip.style.setProperty("--lift", String(1 - progress))
			flyer.target.style.opacity = targetOpacity
		}

		hero.classList.toggle("is-landed", progress > LANDED_PROGRESS)
	}

	function reset() {
		layout = null
		floating = true
		lastProgress = -1
		app.style.transform = ""
		hero.classList.remove("is-landed")
		for (const flyer of flyers) {
			flyer.bob = 0
			flyer.float.style.animationPlayState = ""
			flyer.move.style.transform = ""
			flyer.move.style.opacity = ""
			flyer.chip.style.transform = ""
			flyer.chip.style.removeProperty("--lift")
			flyer.target.style.opacity = ""
		}
	}
}

// Layout offsets ignore CSS transforms, so geometry stays stable while the
// app window and chips are mid-flight.
function offsetWithin(element, ancestor) {
	let x = 0
	let y = 0
	let node = element
	while (node && node !== ancestor) {
		x += node.offsetLeft
		y += node.offsetTop
		const parent = node.offsetParent
		if (parent && parent !== ancestor) {
			x += parent.clientLeft
			y += parent.clientTop
		}
		node = parent
	}
	return node === ancestor ? { x, y } : null
}

function currentTranslateY(element) {
	const transform = getComputedStyle(element).transform
	return transform && transform !== "none" ? new DOMMatrixReadOnly(transform).m42 : 0
}
