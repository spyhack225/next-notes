import { Component, lazy, Suspense, type ReactNode } from "react";
import { MotionConfig } from "framer-motion";
import Navbar from "./sections/Navbar";
import Hero from "./sections/Hero";
import Mission from "./sections/Mission";
import HowItWorks from "./sections/HowItWorks";
import Privacy from "./sections/Privacy";
import WhatItDoes from "./sections/WhatItDoes";
import CTA from "./sections/CTA";
import Footer from "./sections/Footer";

const Benchmarks = lazy(() => import("./Benchmarks"));

class BenchmarkBoundary extends Component<{children: ReactNode}, {failed: boolean}> {
  state = {failed: false};
  static getDerivedStateFromError() { return {failed: true}; }
  render() {
    if (this.state.failed) return <main className="max-w-2xl mx-auto px-6 py-20"><a href="/">Next Notes</a><h1 className="text-3xl mt-10 mb-4">Benchmarks couldn’t load.</h1><p className="text-muted-foreground mb-6">The connection may have dropped, or the website was updated while you were browsing. Reload to get the current results.</p><button className="underline" onClick={() => window.location.reload()}>Reload benchmarks</button></main>;
    return this.props.children;
  }
}

export default function App() {
  if (new URLSearchParams(window.location.search).get("page") === "benchmarks") {
    return <BenchmarkBoundary><Suspense fallback={<main className="max-w-2xl mx-auto px-6 py-20" role="status"><a href="/">Next Notes</a><h1 className="text-3xl mt-10 mb-4">Benchmarks</h1><p>Loading results…</p></main>}><Benchmarks /></Suspense></BenchmarkBoundary>;
  }

  // reducedMotion="user" strips the transforms out of every animation on the page and
  // leaves the opacity fades; the orb freezes itself on the frame the app freezes on.
  return (
    <MotionConfig reducedMotion="user">
      <div className="min-h-screen bg-background text-foreground">
        <Navbar />
        <main>
          <Hero />
          <Mission />
          <WhatItDoes />
          <HowItWorks />
          <Privacy />
          <CTA />
        </main>
        <Footer />
      </div>
    </MotionConfig>
  );
}
