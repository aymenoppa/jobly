import { QueryClientProvider } from "@tanstack/react-query";
import { RouterProvider, createBrowserRouter } from "react-router-dom";
import { ConfirmHost } from "@/components/ui/Confirm";
import { Toaster } from "@/components/ui/Toaster";
import { Tooltips } from "@/components/ui/Tooltips";
import { queryClient } from "@/lib/queryClient";
import { routes } from "./routes";

const router = createBrowserRouter(routes);

export function App() {
  return (
    <QueryClientProvider client={queryClient}>
      <RouterProvider router={router} />
      <ConfirmHost />
      <Toaster />
      {/* Every title's tooltip, on every screen: signed in, signing in, and the pages clients see. */}
      <Tooltips />
    </QueryClientProvider>
  );
}
