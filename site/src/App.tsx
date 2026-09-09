import { MotionConfig } from "framer-motion";
import Navbar from "./sections/Navbar";
import Hero from "./sections/Hero";
import HowItWorks from "./sections/HowItWorks";
import Privacy from "./sections/Privacy";
import Mission from "./sections/Mission";
import WhatItDoes from "./sections/WhatItDoes";
import CTA from "./sections/CTA";
import Footer from "./sections/Footer";

export default function App() {
  // reducedMotion="user" strips the transforms out of every animation on the page and
  // leaves the opacity fades; the orb freezes itself on the frame the app freezes on.
  return (
    <MotionConfig reducedMotion="user">
      <div className="min-h-screen bg-background text-foreground">
        <Navbar />
        <main>
          <Hero />
          <HowItWorks />
          <Privacy />
          <Mission />
          <WhatItDoes />
          <CTA />
        </main>
        <Footer />
      </div>
    </MotionConfig>
  );
}
